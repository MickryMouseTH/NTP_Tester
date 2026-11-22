# ntp_checker_gui.py
# -*- coding: utf-8 -*-
"""
NTP Server vs Google NTP Checker (customtkinter GUI) + resizable panes
- เพิ่มตัวแบ่ง (splitter) แบบลากปรับขนาดได้ ด้วย tkinter.PanedWindow
"""

import customtkinter as ctk
import tkinter as tk
from tkinter import messagebox, filedialog
import socket
import struct
import time
from datetime import datetime
import threading
import statistics
import sys
from typing import Optional, Tuple, Dict, Any, List

NTP_DELTA = 2208988800  # seconds between NTP epoch (1900) and UNIX epoch (1970)

def _unix_to_ntp(ts: float) -> Tuple[int, int]:
    t = ts + NTP_DELTA
    sec = int(t)
    frac = int((t - sec) * (1 << 32)) & 0xFFFFFFFF
    return sec, frac

def _ntp_to_unix(sec: int, frac: int) -> float:
    return (sec + float(frac) / (1 << 32)) - NTP_DELTA

def _refid_to_text(refid_bytes: bytes, stratum: int) -> str:
    if stratum == 1:
        try:
            txt = refid_bytes.decode('ascii', errors='ignore').strip()
            if txt:
                return txt
        except Exception:
            pass
    if len(refid_bytes) == 4:
        return ".".join(str(b) for b in refid_bytes)
    return refid_bytes.hex()

class NTPQueryError(Exception):
    pass

class NTPStats:
    def __init__(self, host: str, addr: str, version: int, stratum: int, leap: int,
                 poll: int, precision: int, root_delay: float, root_dispersion: float,
                 refid: str, t1: float, t2: float, t3: float, t4: float):
        self.host = host
        self.addr = addr
        self.version = version
        self.stratum = stratum
        self.leap = leap
        self.poll = poll
        self.precision = precision
        self.root_delay = root_delay
        self.root_dispersion = root_dispersion
        self.refid = refid
        self.t1, self.t2, self.t3, self.t4 = t1, t2, t3, t4
        self.delay = (self.t4 - self.t1) - (self.t3 - self.t2)
        self.offset = ((self.t2 - self.t1) + (self.t3 - self.t4)) / 2.0

    @property
    def estimated_server_time(self) -> float:
        return self.t4 + self.offset

    def as_dict(self) -> Dict[str, Any]:
        return {
            "host": self.host,
            "addr": self.addr,
            "version": self.version,
            "stratum": self.stratum,
            "leap": self.leap,
            "poll": self.poll,
            "precision": self.precision,
            "root_delay_ms": self.root_delay * 1000.0,
            "root_dispersion_ms": self.root_dispersion * 1000.0,
            "refid": self.refid,
            "delay_ms": self.delay * 1000.0,
            "offset_ms": self.offset * 1000.0,
            "server_time": datetime.fromtimestamp(self.estimated_server_time).isoformat(sep=' ', timespec='milliseconds'),
        }

class NTPClientLite:
    def __init__(self, family: int = socket.AF_UNSPEC):
        self.family = family

    def query(self, host: str, port: int = 123, version: int = 4, timeout: float = 2.5) -> NTPStats:
        if version not in (3, 4):
            raise ValueError("NTP version must be 3 or 4")
        try:
            infos = socket.getaddrinfo(host, port, self.family, socket.SOCK_DGRAM)
        except socket.gaierror as e:
            raise NTPQueryError(f"DNS lookup failed for {host}: {e}") from e

        last_err: Optional[Exception] = None
        for af, socktype, proto, canonname, sa in infos:
            try:
                with socket.socket(af, socket.SOCK_DGRAM, proto) as s:
                    s.settimeout(timeout)
                    li = 0
                    mode = 3
                    vn = version
                    pkt = bytearray(48)
                    pkt[0] = (li << 6) | (vn << 3) | mode
                    t1 = time.time()
                    sec, frac = _unix_to_ntp(t1)
                    struct.pack_into("!II", pkt, 40, sec, frac)
                    s.sendto(pkt, sa)
                    data, addr = s.recvfrom(512)
                    t4 = time.time()

                if len(data) < 48:
                    raise NTPQueryError(f"Incomplete NTP reply from {addr[0]}")

                li_vn_mode, stratum, poll, precision = struct.unpack("!BBBb", data[0:4])
                li = (li_vn_mode >> 6) & 0x3
                vn = (li_vn_mode >> 3) & 0x7
                root_delay = struct.unpack("!i", data[4:8])[0] / float(1 << 16)
                root_dispersion = struct.unpack("!I", data[8:12])[0] / float(1 << 16)
                refid_raw = data[12:16]
                refid = _refid_to_text(refid_raw, stratum)

                (ref_sec, ref_frac,
                 org_sec, org_frac,
                 rec_sec, rec_frac,
                 tx_sec, tx_frac) = struct.unpack("!IIIIIIII", data[16:48])

                t1_echo = _ntp_to_unix(org_sec, org_frac)
                t2 = _ntp_to_unix(rec_sec, rec_frac)
                t3 = _ntp_to_unix(tx_sec, tx_frac)
                if abs(t1_echo - t1) > 2 * timeout:
                    t1_use = t1
                else:
                    t1_use = t1_echo

                return NTPStats(
                    host=host, addr=addr[0], version=vn, stratum=stratum, leap=li,
                    poll=poll, precision=precision, root_delay=root_delay,
                    root_dispersion=root_dispersion, refid=refid,
                    t1=t1_use, t2=t2, t3=t3, t4=t4
                )
            except Exception as e:
                last_err = e
                continue

        if last_err:
            raise NTPQueryError(f"Failed to query {host}: {last_err}") from last_err
        raise NTPQueryError(f"Failed to query {host}: unknown error")

def median_stat(samples: List[NTPStats]) -> Dict[str, Any]:
    if not samples:
        raise ValueError("No samples")
    off = statistics.median(s.offset for s in samples)
    dly = statistics.median(s.delay for s in samples)
    last = samples[-1]
    info = last.as_dict()
    info["offset_ms"] = off * 1000.0
    info["delay_ms"] = dly * 1000.0
    return info

# -------------------- GUI --------------------

class App(ctk.CTk):
    def __init__(self):
        super().__init__()
        ctk.set_appearance_mode("System")
        ctk.set_default_color_theme("blue")

        self.title("NTP Server vs Google NTP Checker")
        self.geometry("980x640")
        self.minsize(900, 600)

        # ---- Variables
        self.var_target_host = ctk.StringVar(value="pool.ntp.org")
        self.var_google_host = ctk.StringVar(value="time.google.com")
        self.var_timeout = ctk.DoubleVar(value=2.5)
        self.var_version = ctk.StringVar(value="4")
        self.var_family = ctk.StringVar(value="Auto")
        self.var_threshold = ctk.DoubleVar(value=100.0)
        self.var_samples = ctk.IntVar(value=3)
        self.var_interval = ctk.DoubleVar(value=5.0)
        self.var_auto = ctk.BooleanVar(value=False)

        self._auto_job = None
        self._work_thread = None
        self._lock = threading.Lock()

        # ---- Layout base: PanedWindow (root)  [controls | results]
        self.grid_rowconfigure(0, weight=1)
        self.grid_columnconfigure(0, weight=1)

        base_bg = "#1f1f1f" if ctk.get_appearance_mode() == "Dark" else "#ebebeb"
        self.hsplit = tk.PanedWindow(self, orient="horizontal", sashwidth=8, bd=0, relief="flat", bg=base_bg)
        self.hsplit.grid(row=0, column=0, sticky="nsew", padx=6, pady=6)

        self.panel_controls = ctk.CTkFrame(self.hsplit, corner_radius=8)
        self.panel_results  = ctk.CTkFrame(self.hsplit, corner_radius=8)

        # เพิ่มลงใน PanedWindow พร้อมกำหนดขนาดขั้นต่ำ
        self.hsplit.add(self.panel_controls, minsize=260)
        self.hsplit.add(self.panel_results,  minsize=420)

        # สร้าง UI ภายในแต่ละ pane
        self._build_controls()
        self._build_results()

        # ตำแหน่งเริ่มต้นของตัวแบ่ง (ตั้งทีหลังเพื่อให้ geometry เสถียร)
        self.after(250, self._place_initial_sashes)

    # ---------- Controls (left pane)
    def _build_controls(self):
        f = self.panel_controls
        # ใช้ grid ภายใน frame นี้ได้ตามปกติ
        f.columnconfigure(0, weight=1)

        ctk.CTkLabel(f, text="ตั้งค่า", font=ctk.CTkFont(size=18, weight="bold")).grid(row=0, column=0, sticky="w", padx=12, pady=(12,4))

        ctk.CTkLabel(f, text="NTP Server (ทดสอบ)").grid(row=1, column=0, sticky="w", padx=12, pady=(8,0))
        ctk.CTkEntry(f, textvariable=self.var_target_host, placeholder_text="host หรือ IP").grid(row=2, column=0, sticky="ew", padx=12, pady=4)

        ctk.CTkLabel(f, text="Reference (Google NTP)").grid(row=3, column=0, sticky="w", padx=12, pady=(8,0))
        ctk.CTkEntry(f, textvariable=self.var_google_host).grid(row=4, column=0, sticky="ew", padx=12, pady=4)

        opt_row = ctk.CTkFrame(f)
        opt_row.grid(row=5, column=0, sticky="ew", padx=8, pady=(8,4))
        opt_row.columnconfigure((0,1), weight=1)
        ctk.CTkLabel(opt_row, text="NTP v").grid(row=0, column=0, sticky="w", padx=4, pady=2)
        ctk.CTkOptionMenu(opt_row, values=["4", "3"], variable=self.var_version, width=80).grid(row=0, column=1, sticky="e", padx=4, pady=2)

        opt_row2 = ctk.CTkFrame(f)
        opt_row2.grid(row=6, column=0, sticky="ew", padx=8, pady=4)
        opt_row2.columnconfigure((0,1,2), weight=1)
        ctk.CTkLabel(opt_row2, text="Address Family").grid(row=0, column=0, sticky="w", padx=4, pady=2)
        ctk.CTkOptionMenu(opt_row2, values=["Auto", "IPv4", "IPv6"], variable=self.var_family, width=100).grid(row=0, column=1, sticky="e", padx=4, pady=2)

        opt_row3 = ctk.CTkFrame(f)
        opt_row3.grid(row=7, column=0, sticky="ew", padx=8, pady=4)
        opt_row3.columnconfigure((0,1,2,3), weight=1)
        ctk.CTkLabel(opt_row3, text="Timeout (s)").grid(row=0, column=0, sticky="w", padx=4, pady=2)
        ctk.CTkEntry(opt_row3, width=80, textvariable=self.var_timeout).grid(row=0, column=1, sticky="e", padx=4, pady=2)
        ctk.CTkLabel(opt_row3, text="Samples").grid(row=0, column=2, sticky="w", padx=4, pady=2)
        ctk.CTkEntry(opt_row3, width=80, textvariable=self.var_samples).grid(row=0, column=3, sticky="e", padx=4, pady=2)

        opt_row4 = ctk.CTkFrame(f)
        opt_row4.grid(row=8, column=0, sticky="ew", padx=8, pady=4)
        opt_row4.columnconfigure((0,1,2,3), weight=1)
        ctk.CTkLabel(opt_row4, text="Threshold |Δ| (ms)").grid(row=0, column=0, sticky="w", padx=4, pady=2)
        ctk.CTkEntry(opt_row4, width=80, textvariable=self.var_threshold).grid(row=0, column=1, sticky="e", padx=4, pady=2)
        ctk.CTkLabel(opt_row4, text="Auto interval (s)").grid(row=0, column=2, sticky="w", padx=4, pady=2)
        ctk.CTkEntry(opt_row4, width=80, textvariable=self.var_interval).grid(row=0, column=3, sticky="e", padx=4, pady=2)

        ctk.CTkSwitch(f, text="Auto", variable=self.var_auto, command=self._toggle_auto).grid(row=9, column=0, sticky="w", padx=12, pady=(8,4))

        btn_row = ctk.CTkFrame(f)
        btn_row.grid(row=10, column=0, sticky="ew", padx=8, pady=(8,12))
        btn_row.columnconfigure((0,1), weight=1)
        ctk.CTkButton(btn_row, text="เช็คตอนนี้", command=self._run_check, width=120).grid(row=0, column=0, padx=6, pady=6, sticky="ew")
        ctk.CTkButton(btn_row, text="Export CSV", command=self._export_csv).grid(row=0, column=1, padx=6, pady=6, sticky="ew")

        ctk.CTkLabel(f, text="© NTP checker — UDP/123", font=ctk.CTkFont(size=11)).grid(row=11, column=0, sticky="w", padx=12, pady=(4,12))

    # ---------- Results (right pane)
    def _build_results(self):
        pr = self.panel_results
        pr.rowconfigure(1, weight=1)   # แถวของ vsplit ขยายได้
        pr.columnconfigure(0, weight=1)

        # Header ด้านบน
        header = ctk.CTkFrame(pr)
        header.grid(row=0, column=0, sticky="ew", padx=12, pady=12)
        header.columnconfigure((0,1,2,3), weight=1)

        self.lbl_time = ctk.CTkLabel(header, text="เวลาท้องถิ่น: -")
        self.lbl_time.grid(row=0, column=0, sticky="w")
        self.lbl_status = ctk.CTkLabel(header, text="สถานะ: พร้อม", font=ctk.CTkFont(weight="bold"))
        self.lbl_status.grid(row=0, column=1, sticky="w", padx=12)
        self.lbl_delta = ctk.CTkLabel(header, text="Δ (target - google): - ms", font=ctk.CTkFont(size=16, weight="bold"))
        self.lbl_delta.grid(row=0, column=2, sticky="w", padx=12)
        self.lbl_pass = ctk.CTkLabel(header, text="PASS/FAIL: -", font=ctk.CTkFont(size=16, weight="bold"))
        self.lbl_pass.grid(row=0, column=3, sticky="w", padx=12)

        # V-split: [top cards] | [log]
        base_bg = "#1f1f1f" if ctk.get_appearance_mode() == "Dark" else "#ebebeb"
        self.vsplit = tk.PanedWindow(pr, orient="vertical", sashwidth=8, bd=0, relief="flat", bg=base_bg)
        self.vsplit.grid(row=1, column=0, sticky="nsew", padx=12, pady=(0,12))

        # ----- โซนบน: การ์ด (ใช้ H-split)
        self.top_area = ctk.CTkFrame(self.vsplit)
        self.vsplit.add(self.top_area, minsize=200)

        self.cards_hsplit = tk.PanedWindow(self.top_area, orient="horizontal", sashwidth=8, bd=0, relief="flat", bg=base_bg)
        self.cards_hsplit.pack(fill="both", expand=True)

        self.card_target = self._make_result_card(self.cards_hsplit, title="ผลลัพธ์: NTP Server (ทดสอบ)")
        self.cards_hsplit.add(self.card_target, minsize=260)

        self.card_google = self._make_result_card(self.cards_hsplit, title="ผลลัพธ์: Google NTP")
        self.cards_hsplit.add(self.card_google, minsize=260)

        # ----- โซนล่าง: Log
        self.log_area = ctk.CTkFrame(self.vsplit)
        self.vsplit.add(self.log_area, minsize=120)

        self.txt_log = ctk.CTkTextbox(self.log_area, wrap="none")
        self.txt_log.pack(fill="both", expand=True)
        self.txt_log.insert("end", "Log started...\n")
        self.txt_log.configure(state="disabled")

    def _place_initial_sashes(self):
        """ตั้งค่าตำแหน่งเริ่มต้นของ splitter (ลากปรับได้ภายหลัง)"""
        try:
            # แบ่งซ้าย/ขวา: ซ้าย ~340px
            self.hsplit.sash_place(0, 340, 1)
        except Exception:
            pass
        try:
            # บน/ล่างในผลลัพธ์: บน ~60%
            h = max(1, self.panel_results.winfo_height())
            self.vsplit.sash_place(0, 1, int(h * 0.60))
        except Exception:
            pass
        try:
            # ซ้าย/ขวาในส่วนการ์ด: ครึ่ง/ครึ่ง
            w = max(1, self.panel_results.winfo_width())
            self.cards_hsplit.sash_place(0, int(w * 0.50), 1)
        except Exception:
            pass

    # ---------- การ์ดผลลัพธ์
    def _make_result_card(self, parent, title: str) -> ctk.CTkFrame:
        card = ctk.CTkFrame(parent)
        card.columnconfigure(0, weight=1)
        ctk.CTkLabel(card, text=title, font=ctk.CTkFont(size=15, weight="bold")).grid(row=0, column=0, sticky="w", padx=12, pady=(12,4))

        grid = ctk.CTkFrame(card)
        grid.grid(row=1, column=0, sticky="ew", padx=12, pady=(0,12))
        for i in range(0, 10):
            grid.rowconfigure(i, weight=0)
        grid.columnconfigure((0,1), weight=1)

        fields = [
            ("Host/Addr", "host_addr"),
            ("Stratum", "stratum"),
            ("Leap", "leap"),
            ("RefID", "refid"),
            ("Root Delay (ms)", "root_delay_ms"),
            ("Root Dispersion (ms)", "root_dispersion_ms"),
            ("Precision (2^x s)", "precision"),
            ("Delay / RTT (ms)", "delay_ms"),
            ("Offset (ms)", "offset_ms"),
            ("Server time (est.)", "server_time"),
        ]
        labels = {}
        for i, (k, key) in enumerate(fields):
            ctk.CTkLabel(grid, text=f"{k}").grid(row=i, column=0, sticky="w", pady=2)
            lbl = ctk.CTkLabel(grid, text="-")
            lbl.grid(row=i, column=1, sticky="e", pady=2)
            labels[key] = lbl

        card._labels = labels
        return card

    # ---------- Helpers
    def _set_card_values(self, card: ctk.CTkFrame, info: Optional[Dict[str, Any]]):
        labels = getattr(card, "_labels", {})
        def setv(key, val):
            if key in labels:
                labels[key].configure(text=str(val))
        if info is None:
            for k in labels: labels[k].configure(text="-")
            return
        setv("host_addr", f"{info.get('host','')} / {info.get('addr','')}")
        setv("stratum", info.get("stratum", "-"))
        leap = info.get("leap", 0)
        setv("leap", f"{leap} ({'unsync' if leap==3 else 'ok'})")
        setv("refid", info.get("refid", "-"))
        setv("root_delay_ms", f"{info.get('root_delay_ms', 0):.3f}")
        setv("root_dispersion_ms", f"{info.get('root_dispersion_ms', 0):.3f}")
        setv("precision", info.get("precision", "-"))
        setv("delay_ms", f"{info.get('delay_ms', 0):.3f}")
        setv("offset_ms", f"{info.get('offset_ms', 0):.3f}")
        setv("server_time", info.get("server_time", "-"))

    def _toggle_auto(self):
        if self.var_auto.get():
            self._schedule_auto()
        else:
            if self._auto_job:
                self.after_cancel(self._auto_job)
                self._auto_job = None

    def _schedule_auto(self):
        if not self.var_auto.get():
            return
        self._run_check()
        interval_ms = max(200, int(self.var_interval.get() * 1000))
        self._auto_job = self.after(interval_ms, self._schedule_auto)

    def _family_value(self) -> int:
        fam = self.var_family.get()
        if fam == "IPv4":
            return socket.AF_INET
        if fam == "IPv6":
            return socket.AF_INET6
        return socket.AF_UNSPEC

    def _run_check(self):
        with self._lock:
            if self._work_thread and self._work_thread.is_alive():
                return
            self._work_thread = threading.Thread(target=self._worker_check, daemon=True)
            self._work_thread.start()

    def _worker_check(self):
        self._set_status("กำลังเช็ค...", bold=True)
        self._update_now_label()

        host_target = self.var_target_host.get().strip()
        host_google = self.var_google_host.get().strip()
        timeout = float(self.var_timeout.get())
        version = int(self.var_version.get())
        samples = max(1, int(self.var_samples.get()))
        family = self._family_value()
        threshold = float(self.var_threshold.get())

        client = NTPClientLite(family=family)

        def sample_host(h: str) -> List[NTPStats]:
            lst = []
            for _ in range(samples):
                stat = client.query(h, version=version, timeout=timeout)
                lst.append(stat)
                if samples > 1:
                    time.sleep(0.12)
            return lst

        target_info = None
        google_info = None
        error_msgs = []

        try:
            t_samples = sample_host(host_target)
            target_info = median_stat(t_samples)
        except Exception as e:
            error_msgs.append(f"Target error: {e}")

        try:
            g_samples = sample_host(host_google)
            google_info = median_stat(g_samples)
        except Exception as e:
            error_msgs.append(f"Google error: {e}")

        def apply_updates():
            self._set_card_values(self.card_target, target_info)
            self._set_card_values(self.card_google, google_info)

            if target_info and google_info:
                delta_ms = target_info["offset_ms"] - google_info["offset_ms"]
                self.lbl_delta.configure(text=f"Δ (target - google): {delta_ms:.3f} ms")
                passed = abs(delta_ms) <= threshold
                self.lbl_pass.configure(
                    text=("PASS" if passed else "FAIL") + f" (|Δ| ≤ {threshold:.1f} ms)",
                    text_color=("#08a045" if passed else "#cc2936")
                )
                self._append_log(
                    f"[OK] {datetime.now().isoformat(sep=' ', timespec='seconds')} "
                    f"Δ={delta_ms:.3f} ms | target off={target_info['offset_ms']:.3f} ms | "
                    f"google off={google_info['offset_ms']:.3f} ms | thr={threshold:.1f} ms\n"
                )
                self._set_status("สำเร็จ", bold=True)
            else:
                self.lbl_delta.configure(text="Δ (target - google): -")
                self.lbl_pass.configure(text="PASS/FAIL: -", text_color=None)
                if error_msgs:
                    self._append_log("[ERR] " + " | ".join(error_msgs) + "\n")
                    self._set_status("ผิดพลาด", bold=True)
                else:
                    self._append_log("[WARN] ไม่สามารถคำนวณผลลัพธ์ได้\n")
                    self._set_status("คำเตือน", bold=True)

        self.after(0, apply_updates)

    def _update_now_label(self):
        self.lbl_time.configure(text=f"เวลาท้องถิ่น: {datetime.now().isoformat(sep=' ', timespec='seconds')}")

    def _set_status(self, text: str, bold: bool = False):
        self.lbl_status.configure(text=f"สถานะ: {text}", font=ctk.CTkFont(weight="bold" if bold else "normal"))

    def _append_log(self, text: str):
        self.txt_log.configure(state="normal")
        self.txt_log.insert("end", text)
        self.txt_log.see("end")
        self.txt_log.configure(state="disabled")

    def _export_csv(self):
        def collect(card: ctk.CTkFrame) -> Dict[str, str]:
            labels = getattr(card, "_labels", {})
            def getv(key):
                return labels[key].cget("text") if key in labels else "-"
            return {
                "host_addr": getv("host_addr"),
                "stratum": getv("stratum"),
                "leap": getv("leap"),
                "refid": getv("refid"),
                "root_delay_ms": getv("root_delay_ms"),
                "root_dispersion_ms": getv("root_dispersion_ms"),
                "precision": getv("precision"),
                "delay_ms": getv("delay_ms"),
                "offset_ms": getv("offset_ms"),
                "server_time": getv("server_time"),
            }

        tgt = collect(self.card_target)
        ggl = collect(self.card_google)
        delta_text = self.lbl_delta.cget("text")

        fname = filedialog.asksaveasfilename(
            defaultextension=".csv",
            filetypes=[("CSV files", "*.csv")],
            initialfile=f"ntp_check_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv",
            title="Export CSV"
        )
        if not fname:
            return

        try:
            import csv
            with open(fname, "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow(["Generated", datetime.now().isoformat(sep=' ', timespec='seconds')])
                w.writerow([])
                w.writerow(["Δ summary", delta_text])
                w.writerow([])
                w.writerow(["Section", "Host/Addr", "Stratum", "Leap", "RefID", "Root Delay (ms)",
                            "Root Dispersion (ms)", "Precision", "Delay (ms)", "Offset (ms)", "Server time"])
                w.writerow(["Target", *tgt.values()])
                w.writerow(["Google", *ggl.values()])
            messagebox.showinfo("Export CSV", f"บันทึกแล้ว: {fname}")
        except Exception as e:
            messagebox.showerror("Export CSV", f"ผิดพลาดในการบันทึก: {e}")

if __name__ == "__main__":
    try:
        app = App()
        app.mainloop()
    except KeyboardInterrupt:
        sys.exit(0)
