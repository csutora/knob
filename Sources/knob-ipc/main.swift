@preconcurrency import Foundation
import Security

// Shared memory layout (must match driver and daemon):
// Bytes 0–7:  Int64 write position
// Bytes 8–63: reserved (cache-line aligned header)
// Bytes 64+:  ring buffer (65536 frames x 2 channels x sizeof(Float))

private let kShmHeaderSize = 64
private let kRingBufferFrames = 65536
private let kChannelCount = 2
private let kTotalSize = kShmHeaderSize + kRingBufferFrames * kChannelCount * MemoryLayout<Float>.size

private let kServiceName = "com.csutora.knob.ipc"
private let kCoreaudiodUID: uid_t = 202  // _coreaudiod

func log(_ message: String) {
    fputs("knob-ipc: \(message)\n", stderr)
}

// MARK: - Code signing verification

/// Extract the leaf certificate DER bytes from a SecCode.
func leafCertificateData(from code: SecCode) -> Data? {
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
          let sc = staticCode else { return nil }

    var info: CFDictionary?
    guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any],
          let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certs.first else { return nil }

    return SecCertificateCopyData(leaf) as Data
}

/// Cache own leaf certificate at startup.
/// Returns nil if this binary is ad-hoc signed (no certificate).
func getOwnLeafCertificate() -> Data? {
    var selfCode: SecCode?
    guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
          let code = selfCode else {
        log("SecCodeCopySelf failed")
        return nil
    }
    return leafCertificateData(from: code)
}

/// Verify a peer process (by PID) is signed with the same certificate as us.
func verifyPeerSignature(pid: pid_t, ownLeafData: Data) -> Bool {
    let attrs = [kSecGuestAttributePid: pid] as CFDictionary
    var guestCode: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &guestCode) == errSecSuccess,
          let code = guestCode else {
        log("SecCodeCopyGuestWithAttributes failed for pid \(pid)")
        return false
    }

    // Verify signature integrity without network (avoids OCSP/CRL for self-signed cert)
    guard SecCodeCheckValidity(code, [.noNetworkAccess], nil) == errSecSuccess else {
        log("SecCodeCheckValidity failed for pid \(pid)")
        return false
    }

    guard let peerLeaf = leafCertificateData(from: code) else {
        log("no leaf certificate for pid \(pid)")
        return false
    }

    return peerLeaf == ownLeafData
}

// MARK: - Startup

// 1. Cache own leaf certificate
let ownLeafData: Data? = getOwnLeafCertificate()
if let data = ownLeafData {
    log("own leaf certificate: \(data.count) bytes")
} else {
    log("WARNING: not properly signed — will refuse daemon connections")
}

// 2. Allocate shared memory via Mach VM
var memAddress: mach_vm_address_t = 0
var kr = mach_vm_allocate(mach_task_self_, &memAddress, mach_vm_size_t(kTotalSize), VM_FLAGS_ANYWHERE)
guard kr == KERN_SUCCESS else {
    log("mach_vm_allocate failed: \(kr)")
    exit(1)
}
memset(UnsafeMutableRawPointer(bitPattern: UInt(memAddress))!, 0, kTotalSize)
log("allocated \(kTotalSize) bytes")

// 3. Create memory entries (kernel-enforced access control)

// Read-write entry for the driver
nonisolated(unsafe) var rwPort: mach_port_t = mach_port_t(MACH_PORT_NULL)
var rwSize = memory_object_size_t(kTotalSize)
kr = mach_make_memory_entry_64(
    mach_task_self_, &rwSize, memory_object_offset_t(memAddress),
    VM_PROT_READ | VM_PROT_WRITE, &rwPort, mach_port_t(MACH_PORT_NULL))
guard kr == KERN_SUCCESS else {
    log("memory entry (rw) failed: \(kr)")
    exit(1)
}

// Read-only entry for the daemon
nonisolated(unsafe) var roPort: mach_port_t = mach_port_t(MACH_PORT_NULL)
var roSize = memory_object_size_t(kTotalSize)
kr = mach_make_memory_entry_64(
    mach_task_self_, &roSize, memory_object_offset_t(memAddress),
    VM_PROT_READ, &roPort, mach_port_t(MACH_PORT_NULL))
guard kr == KERN_SUCCESS else {
    log("memory entry (ro) failed: \(kr)")
    exit(1)
}

log("memory entries: rw port=\(rwPort) ro port=\(roPort)")

// 4. XPC Mach service listener

let listener = xpc_connection_create_mach_service(
    kServiceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))

xpc_connection_set_event_handler(listener) { peer in
    xpc_connection_set_event_handler(peer) { event in
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else { return }
        guard let reply = xpc_dictionary_create_reply(event) else { return }

        let uid = xpc_connection_get_euid(peer)
        let pid = xpc_connection_get_pid(peer)

        if uid == kCoreaudiodUID {
            // Driver (coreaudiod) — read-write access, no cert check
            xpc_dictionary_set_mach_send(reply, "memory", rwPort)
            xpc_dictionary_set_uint64(reply, "size", UInt64(kTotalSize))
            log("granted rw to pid \(pid) (coreaudiod)")
        } else if let leafData = ownLeafData, verifyPeerSignature(pid: pid, ownLeafData: leafData) {
            // Same signer — read-only access
            xpc_dictionary_set_mach_send(reply, "memory", roPort)
            xpc_dictionary_set_uint64(reply, "size", UInt64(kTotalSize))
            log("granted ro to pid \(pid) (verified same signer)")
        } else {
            xpc_dictionary_set_string(reply, "error", "unauthorized")
            if ownLeafData == nil {
                log("rejected pid \(pid): helper not properly signed")
            } else {
                log("rejected pid \(pid) (uid \(uid)): signature mismatch")
            }
        }

        xpc_connection_send_message(peer, reply)
    }
    xpc_connection_resume(peer)
}

xpc_connection_resume(listener)
log("listening on \(kServiceName)")

dispatchMain()
