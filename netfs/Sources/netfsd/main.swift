//
//  netfsd -- serve a host directory to Research Unix over TCP. Phase N5.
//
//  Usage: netfsd [-p port] [-w] [-v] [-u uid] [-g gid] <directory>
//
//    -p  TCP port on 127.0.0.1 (default 9200)
//    -w  read/write; the default is read-only
//    -v  trace every request
//    -u  uid to present every file as (default 0)
//    -g  gid to present every file as (default 0)
//
//  The guest reaches this at 10.0.2.2:<port>. Nothing has to be forwarded:
//  SLiRP redirects every address inside its virtual network to the host's
//  loopback, so 10.0.2.2 *is* 127.0.0.1 as far as a connection is concerned.
//
import Foundation
import NetFS

var port: UInt16 = 9200
var readOnly = true
var verbose = false
var mapUID: UInt16 = 0
var mapGID: UInt16 = 0
var root: String? = nil

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "-p": port = UInt16(args.removeFirst()) ?? 9200
    case "-w": readOnly = false
    case "-v": verbose = true
    case "-u": mapUID = UInt16(args.removeFirst()) ?? 0
    case "-g": mapGID = UInt16(args.removeFirst()) ?? 0
    case "-h", "--help":
        print("usage: netfsd [-p port] [-w] [-v] [-u uid] [-g gid] <directory>")
        exit(0)
    default:
        root = arg
    }
}

guard let root else {
    FileHandle.standardError.write(Data("netfsd: no directory to export\n".utf8))
    exit(2)
}

var st = stat()
guard lstat(root, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else {
    FileHandle.standardError.write(Data("netfsd: \(root) is not a directory\n".utf8))
    exit(2)
}

// Resolve to an absolute path once, here. Every path the server builds is this
// one plus components, and a relative root would silently follow a chdir.
let absolute = (root as NSString).isAbsolutePath
    ? root : FileManager.default.currentDirectoryPath + "/" + root

let server = NetFSServer(NetFSConfig(root: (absolute as NSString).standardizingPath,
                                     port: port, readOnly: readOnly,
                                     mapUID: mapUID, mapGID: mapGID, verbose: verbose))
do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("netfsd: \(error)\n".utf8))
    exit(1)
}
server.serveForever()
