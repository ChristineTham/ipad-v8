//! Headless DMD 5620 bridge.
//!
//! Connects Seth Morabito's dmd_core (WE32100 DMD 5620 emulator) to SIMH's
//! DZ11 telnet listener, auto-logs-in to Research Unix V8, starts mux, and
//! dumps the 800x1024 framebuffer to PNG files as visual proof. This is a
//! desktop prototype of exactly the embedding the iPad app performs.

use dmd_core::dmd::Dmd;
use std::collections::VecDeque;
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

const FB_W: usize = 800;
const FB_H: usize = 1024;
const FB_BYTES: usize = FB_W * FB_H / 8;

const IAC: u8 = 255;
const DONT: u8 = 254;
const DO: u8 = 253;
const WONT: u8 = 252;
const WILL: u8 = 251;

/// Stateful telnet-IAC parser for the SIMH-to-us direction.
struct Telnet {
    state: u8, // 0 = data, 1 = saw IAC, 2 = saw IAC+verb (verb stored)
    verb: u8,
}

impl Telnet {
    fn new() -> Self {
        Telnet { state: 0, verb: 0 }
    }
    fn push(&mut self, b: u8, out: &mut VecDeque<u8>, reply: &mut Vec<u8>) {
        match self.state {
            0 => {
                if b == IAC {
                    self.state = 1;
                } else {
                    out.push_back(b);
                }
            }
            1 => match b {
                IAC => {
                    out.push_back(IAC);
                    self.state = 0;
                }
                DO | DONT | WILL | WONT => {
                    self.verb = b;
                    self.state = 2;
                }
                _ => self.state = 0,
            },
            _ => {
                match self.verb {
                    DO => reply.extend_from_slice(&[IAC, WONT, b]),
                    WILL => reply.extend_from_slice(&[IAC, DONT, b]),
                    _ => {}
                }
                self.state = 0;
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Phase {
    WaitLogin,
    WaitShell,
    MuxRunning,
    Gestures,
    Done,
}

enum Act {
    Move(u16, u16),
    Down(u8),
    Up(u8),
    Shot(&'static str),
}

fn dump_png(dir: &str, n: u32, label: &str, secs: f64, fb: &[u8]) {
    let path = format!("{dir}/shot_{n:02}_{label}_t{secs:.1}.png");
    let file = match fs::File::create(&path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("png create failed: {e}");
            return;
        }
    };
    let mut enc = png::Encoder::new(file, FB_W as u32, FB_H as u32);
    enc.set_color(png::ColorType::Grayscale);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header().expect("png header");
    let mut pixels = Vec::with_capacity(FB_W * FB_H);
    for row in 0..FB_H {
        for col in 0..FB_W / 8 {
            let byte = fb[row * (FB_W / 8) + col];
            for bit in 0..8 {
                // 1-bit = lit phosphor -> white on black
                pixels.push(if byte & (0x80 >> bit) != 0 { 255 } else { 0 });
            }
        }
    }
    writer.write_image_data(&pixels).expect("png data");
    println!("[{secs:7.2}s] wrote {path}");
}

fn fb_hash(fb: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in fb {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

fn main() {
    let shots_dir = std::env::args().nth(1).unwrap_or_else(|| "shots".into());
    fs::create_dir_all(&shots_dir).expect("mkdir shots");

    // Connect (retry: SIMH may still be booting).
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut sock = loop {
        match TcpStream::connect("127.0.0.1:8888") {
            Ok(s) => break s,
            Err(e) => {
                if Instant::now() > deadline {
                    panic!("could not connect to SIMH DZ: {e}");
                }
                std::thread::sleep(Duration::from_secs(2));
            }
        }
    };
    sock.set_nonblocking(true).unwrap();
    sock.set_nodelay(true).ok();
    println!("connected to SIMH DZ on 127.0.0.1:8888");

    let mut dmd = Dmd::new();
    dmd.reset().expect("dmd reset");
    println!("dmd_core reset; video_ram len = {}", dmd.video_ram().len());

    let t0 = Instant::now();
    let secs = |t: Instant| t.duration_since(t0).as_secs_f64();

    let mut telnet = Telnet::new();
    let mut rxq: VecDeque<u8> = VecDeque::new(); // host -> terminal, paced
    let mut txbuf: Vec<u8> = Vec::new(); // terminal -> host, IAC-escaped
    let mut scan: Vec<u8> = Vec::new(); // parity-stripped host stream for prompts
    let mut kbq: VecDeque<u8> = VecDeque::new(); // pending keystrokes
    let mut phase = Phase::WaitLogin;

    // Metrics.
    let mut host_bytes_total: u64 = 0;
    let mut mux_t: Option<Instant> = None;
    let mut burst_bytes: u64 = 0;
    let mut last_rx_at = Instant::now();
    let mut download_done_at: Option<Instant> = None;

    // Framebuffer snapshots.
    let mut fbbuf = vec![0u8; FB_BYTES];
    let mut last_hash: u64 = 0;
    let mut last_shot = Instant::now() - Duration::from_secs(10);
    let mut last_fb_check = Instant::now();
    let mut shot_n: u32 = 0;

    // Mouse gesture script: open the button-3 menu, select an item, then
    // sweep a rectangle with button 3 (the classic "New layer" flow).
    let gestures: Vec<(u64, Act)> = vec![
        (0, Act::Move(400, 500)),
        (300, Act::Down(3)),
        (900, Act::Move(400, 460)),
        (1500, Act::Shot("menu")),
        (1800, Act::Up(3)),
        (2600, Act::Shot("aftermenu")),
        (3000, Act::Move(180, 260)),
        (3300, Act::Down(3)),
        (3700, Act::Move(340, 430)),
        (4100, Act::Move(500, 610)),
        (4500, Act::Move(620, 820)),
        (4900, Act::Up(3)),
        (7000, Act::Shot("layer")),
    ];
    let mut gest_i = 0usize;
    let mut gest_t0: Option<Instant> = None;

    let mut iter: u64 = 0;
    let mut kb_gap: u64 = 0;
    let hard_stop = t0 + Duration::from_secs(1500);
    let mut done_at: Option<Instant> = None;
    let mut last_progress = Instant::now();
    const MUXTERM_SIZE: u64 = 144_603; // ls -l /usr/jerq/lib/muxterm on the V8 image

    loop {
        dmd.run(500);
        iter += 1;

        // Paced host->terminal injection: one byte per ~1000 emulated steps.
        if iter % 2 == 0 {
            if let Some(b) = rxq.pop_front() {
                dmd.rx_char(b);
                scan.push(b & 0x7f);
                if scan.len() > 8192 {
                    scan.drain(..4096);
                }
            }
        }

        // Terminal -> host (escape IAC for telnet).
        while let Some(b) = dmd.rs232_tx_poll() {
            txbuf.push(b);
            if b == IAC {
                txbuf.push(IAC);
            }
        }
        while dmd.kb_tx_poll().is_some() {} // drain keyboard-channel beeps

        // Keyboard typing, spaced out.
        if kb_gap > 0 {
            kb_gap -= 1;
        } else if let Some(k) = kbq.pop_front() {
            dmd.rx_keyboard(k);
            kb_gap = 40; // ~20k steps between keystrokes
        }

        // Socket I/O.
        if iter % 64 == 0 {
            let mut buf = [0u8; 4096];
            match sock.read(&mut buf) {
                Ok(0) => {
                    println!("[{:7.2}s] SIMH closed the connection", secs(Instant::now()));
                    break;
                }
                Ok(n) => {
                    let mut reply = Vec::new();
                    for &b in &buf[..n] {
                        telnet.push(b, &mut rxq, &mut reply);
                    }
                    if !reply.is_empty() {
                        let _ = sock.write_all(&reply);
                    }
                    host_bytes_total += n as u64;
                    if mux_t.is_some() && download_done_at.is_none() {
                        burst_bytes += n as u64;
                    }
                    last_rx_at = Instant::now();
                }
                Err(ref e) if e.kind() == ErrorKind::WouldBlock => {}
                Err(e) => {
                    println!("socket error: {e}");
                    break;
                }
            }
            if !txbuf.is_empty() {
                match sock.write(&txbuf) {
                    Ok(n) => {
                        txbuf.drain(..n);
                    }
                    Err(ref e) if e.kind() == ErrorKind::WouldBlock => {}
                    Err(e) => {
                        println!("socket write error: {e}");
                        break;
                    }
                }
            }
        }

        // Prompt-driven phase machine.
        let has = |scan: &Vec<u8>, pat: &[u8]| {
            scan.windows(pat.len()).rev().take(2048).any(|w| w == pat)
        };
        match phase {
            Phase::WaitLogin => {
                if has(&scan, b"login:") {
                    println!("[{:7.2}s] login prompt seen; typing root", secs(Instant::now()));
                    kbq.extend(b"root\r");
                    scan.clear();
                    phase = Phase::WaitShell;
                }
            }
            Phase::WaitShell => {
                if has(&scan, b"# ") {
                    println!("[{:7.2}s] shell prompt; starting mux", secs(Instant::now()));
                    kbq.extend(b"/usr/jerq/bin/mux\r");
                    scan.clear();
                    mux_t = Some(Instant::now());
                    phase = Phase::MuxRunning;
                }
            }
            Phase::MuxRunning => {
                // Download complete when we've seen most of muxterm AND the
                // burst has gone properly quiet (block-ack stalls are shorter).
                if let Some(mt) = mux_t {
                    let now = Instant::now();
                    if now.duration_since(last_progress) > Duration::from_secs(30) {
                        last_progress = now;
                        let el = now.duration_since(mt).as_secs_f64();
                        let rate = burst_bytes as f64 / el.max(0.001);
                        let eta = (MUXTERM_SIZE.saturating_sub(burst_bytes)) as f64 / rate.max(1.0);
                        println!(
                            "[{:7.2}s] download progress: {} bytes ({:.0}% of muxterm), {:.0} B/s, ~{:.0}s to go",
                            secs(now),
                            burst_bytes,
                            100.0 * burst_bytes as f64 / MUXTERM_SIZE as f64,
                            rate,
                            eta
                        );
                    }
                    if burst_bytes > MUXTERM_SIZE * 7 / 10
                        && now.duration_since(last_rx_at) > Duration::from_secs(8)
                    {
                        let dl = last_rx_at.duration_since(mt).as_secs_f64();
                        println!(
                            "[{:7.2}s] muxterm download complete: {} bytes in {:.2}s (~{:.0} byte/s)",
                            secs(now),
                            burst_bytes,
                            dl,
                            burst_bytes as f64 / dl.max(0.001)
                        );
                        let tail: Vec<u8> = scan.iter().rev().take(200).rev().cloned().collect();
                        println!("host text tail: {:?}", String::from_utf8_lossy(&tail));
                        download_done_at = Some(now);
                        gest_t0 = Some(now + Duration::from_secs(6));
                        phase = Phase::Gestures;
                    }
                }
            }
            Phase::Gestures => {
                if let Some(g0) = gest_t0 {
                    let now = Instant::now();
                    if now >= g0 && gest_i < gestures.len() {
                        let (off, act) = &gestures[gest_i];
                        if now.duration_since(g0).as_millis() as u64 >= *off {
                            match act {
                                Act::Move(x, y) => dmd.mouse_move(*x, *y),
                                Act::Down(b) => dmd.mouse_down(*b),
                                Act::Up(b) => dmd.mouse_up(*b),
                                Act::Shot(label) => {
                                    let vram = dmd.video_ram();
                                    let n = FB_BYTES.min(vram.len());
                                    fbbuf[..n].copy_from_slice(&vram[..n]);
                                    shot_n += 1;
                                    dump_png(&shots_dir, shot_n, label, secs(now), &fbbuf);
                                }
                            }
                            gest_i += 1;
                        }
                    }
                    if gest_i >= gestures.len() {
                        phase = Phase::Done;
                        done_at = Some(Instant::now() + Duration::from_secs(3));
                    }
                }
            }
            Phase::Done => {}
        }

        // Periodic framebuffer-change snapshots.
        let now = Instant::now();
        if now.duration_since(last_fb_check) > Duration::from_millis(150) {
            last_fb_check = now;
            let vram = dmd.video_ram();
            let n = FB_BYTES.min(vram.len());
            fbbuf[..n].copy_from_slice(&vram[..n]);
            let h = fb_hash(&fbbuf);
            if h != last_hash {
                last_hash = h;
                if now.duration_since(last_shot) > Duration::from_millis(1200) && shot_n < 40 {
                    shot_n += 1;
                    dump_png(&shots_dir, shot_n, "fb", secs(now), &fbbuf);
                    last_shot = now;
                }
            }
        }

        if let Some(d) = done_at {
            if now > d {
                break;
            }
        }
        if now > hard_stop {
            println!("[{:7.2}s] hard stop", secs(now));
            break;
        }
    }

    // Final snapshot + summary.
    let vram = dmd.video_ram();
    let n = FB_BYTES.min(vram.len());
    fbbuf[..n].copy_from_slice(&vram[..n]);
    shot_n += 1;
    dump_png(&shots_dir, shot_n, "final", secs(Instant::now()), &fbbuf);
    println!(
        "summary: phase={phase:?} host_bytes={host_bytes_total} burst_bytes={burst_bytes} shots={shot_n}"
    );
}
