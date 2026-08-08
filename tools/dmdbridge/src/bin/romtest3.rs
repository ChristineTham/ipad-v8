//! Diagnostic 3: single-step disassembly (Debug) of the 8;7;3 wait loop.
use dmd_core::Dmd;

fn main() {
    let mut dmd = Dmd::new();
    dmd.reset(1).expect("reset");
    dmd.run(40_000_000); // deep into the wait loop
    while dmd.rs232_tx().is_some() {}
    for _ in 0..14 {
        dmd.step();
        let s = dmd.ir_debug();
        println!("pc={:06x} {}", dmd.get_pc(), &s[..s.len().min(400)]);
    }
}
