import Darwin
import Foundation

/// Thin wrappers over libproc and sysctl: the same calls `ps` and `lsof` make, without the subprocesses.
enum LibProc {
    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    static func info(_ pid: pid_t) -> ProcInfo? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        // SZOMB: the process has exited and only waits for its parent to collect it.
        guard bsd.pbi_status != 5 else { return nil }

        var name = cString(bsd.pbi_name)
        if name.isEmpty { name = cString(bsd.pbi_comm) }

        var tty: String?
        if bsd.e_tdev != UInt32.max, let dev = devname(dev_t(bitPattern: bsd.e_tdev), S_IFCHR) {
            let value = String(cString: dev)
            if value != "??" { tty = value }
        }

        return ProcInfo(pid: pid,
                        ppid: pid_t(bsd.pbi_ppid),
                        pgid: pid_t(bsd.pbi_pgid),
                        uid: bsd.pbi_uid,
                        name: name,
                        startTime: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000,
                        tty: tty)
    }

    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }()

    static func args(_ pid: pid_t) -> ProcArgs? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: argMax)
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcArgs.parse(Array(buffer.prefix(size)))
    }

    /// TCP sockets in the LISTEN state, one entry per port.
    static func listeningPorts(_ pid: pid_t) -> [(port: UInt16, address: String)] {
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }

        var found: [(port: UInt16, address: String)] = []
        for fd in fds.prefix(Int(filled) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            guard port != 0, !found.contains(where: { $0.port == port }) else { continue }
            found.append((port, address(of: tcp.tcpsi_ini)))
        }
        return found
    }

    private static func address(of ini: in_sockinfo) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var addr = ini.insi_laddr.ina_46.i46a_addr4
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
        } else {
            var addr = ini.insi_laddr.ina_6
            inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
        }
        let text = String(cString: buffer)
        return (text == "0.0.0.0" || text == "::") ? "*" : text
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
