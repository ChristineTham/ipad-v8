//! Diagnostic 4: watch the wait-loop counter word at 0x71C4E0.
use dmd_core::Dmd;

fn main() {
    let mut dmd = Dmd::new();
    dmd.reset(1).expect("reset");
    dmd.run(40_000_000);
    for i in 0..10 {
        let v = dmd.read_word(0x71C4E0);
        let pc = dmd.get_pc();
        println!("sample {i}: counter={v:?} (hex {:x?}) pc={pc:06x}", v);
        dmd.run(5_000_000);
    }
}
