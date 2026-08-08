use dmd_core::Dmd;
fn main() {
    let mut dmd = Dmd::new();
    dmd.reset(1).expect("reset");
    dmd.run(40_000_000);
    for i in 0..6 {
        let r10 = dmd.get_register(10);
        let r0 = dmd.get_register(0);
        let at = dmd.read_word(r10 as usize);
        println!("sample {i}: R10={r10:08x} (word there: {at:x?}) R0={r0:08x} pc={:06x}", dmd.get_pc());
        dmd.run(3_000_000);
    }
}
