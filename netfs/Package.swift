// swift-tools-version: 6.2
//
// The host half of Research Unix's netfs, phase N5.
//
// Two targets on purpose. `NetFS` is the whole server and has no dependency on
// anything a phone does not have -- Foundation and POSIX sockets, no
// Network.framework, no Dispatch queues that assume a main runloop. `netfsd` is
// a thin main() around it so the desktop can drive the thing against SIMH.
//
// That split is the entire point: N7 puts a netfs server inside the iPad app so
// the emulated VAX can mount a folder chosen in Files, and when it does, it
// compiles these same source files. Nothing here may grow a Mac-only
// dependency without breaking that.
import PackageDescription

let package = Package(
    name: "netfs",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "NetFS"),
        .executableTarget(name: "netfsd", dependencies: ["NetFS"]),
    ]
)
