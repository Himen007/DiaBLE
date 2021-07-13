import Foundation
import AVFoundation


// https://fortinetweb.s3.amazonaws.com/fortiguard/research/techreport.pdf
// https://github.com/travisgoodspeed/goodtag/wiki/RF430TAL152H
// https://github.com/travisgoodspeed/GoodV/blob/master/app/src/main/java/com/kk4vcz/goodv/NfcRF430TAL.java
// https://github.com/cryptax/misc-code/blob/master/glucose-tools/readdump.py
// https://github.com/travisgoodspeed/goodtag/blob/master/firmware/gcmpatch.c
// https://github.com/captainbeeheart/openfreestyle/blob/master/docs/reverse.md


struct NFCCommand {
    let code: Int
    var parameters: Data = Data()
    var description: String = ""
}

enum NFCError: LocalizedError {
    case commandNotSupported
    case customCommandError
    case read
    case readBlocks

    var errorDescription: String? {
        switch self {
        case .commandNotSupported: return "command not supported"
        case .customCommandError:  return "custom command error"
        case .read:                return "read error"
        case .readBlocks:          return "reading blocks error"
        }
    }
}


extension Sensor {

    var backdoor: Data {
        switch self.type {
        case .libre1:    return Data([0xc2, 0xad, 0x75, 0x21])
        case .libreProH: return Data([0xc2, 0xad, 0x00, 0x90])
        default:         return Data([0xde, 0xad, 0xbe, 0xef])
        }
    }

    var activationCommand: NFCCommand {
        switch self.type {
        case .libre1, .libreProH:
                      return NFCCommand(code: 0xA0, parameters: backdoor)
        case .libre2: return nfcCommand(.activate)
        default:      return NFCCommand(code: 0x00)
        }
    }

    var universalCommand: NFCCommand   { NFCCommand(code: 0xA1) }

    // Libre 1
    var lockCommand: NFCCommand        { NFCCommand(code: 0xA2, parameters: backdoor) }
    var readRawCommand: NFCCommand     { NFCCommand(code: 0xA3, parameters: backdoor) }
    var unlockCommand: NFCCommand      { NFCCommand(code: 0xA4, parameters: backdoor) }

    // Libre 2 / Pro
    // SEE: custom commands C0-C4 in TI RF430FRL15xH Firmware User's Guide
    var readBlockCommand: NFCCommand   { NFCCommand(code: 0xB0) }
    var readBlocksCommand: NFCCommand  { NFCCommand(code: 0xB3) }

    /// replies with error 0x12 (.contentCannotBeChanged)
    var writeBlockCommand: NFCCommand  { NFCCommand(code: 0xB1) }

    /// replies with errors 0x12 (.contentCannotBeChanged) or 0x0f (.unknown)
    /// writing three blocks is not supported because it exceeds the 32-byte input buffer
    var writeBlocksCommand: NFCCommand { NFCCommand(code: 0xB4) }

    /// Usual 1252 blocks limit:
    /// block 04e3 => error 0x11 (.blockAlreadyLocked)
    /// block 04e4 => error 0x10 (.blockNotAvailable)
    var lockBlockCommand: NFCCommand   { NFCCommand(code: 0xB2) }


    enum Subcommand: UInt8, CustomStringConvertible {
        case unlock          = 0x1a    // lets read FRAM in clear and dump further blocks with B0/B3
        case activate        = 0x1b
        case enableStreaming = 0x1e
        case unknown0x10     = 0x10    // returns the number of parameters + 3
        case unknown0x1c     = 0x1c
        case unknown0x1d     = 0x1d    // disables Bluetooth
        case unknown0x1f     = 0x1f    // unknown secret, GEN_SECURITY_CMD_GET_SESSION_INFO
        // Gen2
        case readChallenge   = 0x20    // returns 25 bytes
        case readBlocks      = 0x21
        case readAttribute   = 0x22    // returns 6 bytes ([0]: sensor state)

        var description: String {
            switch self {
            case .unlock:          return "unlock"
            case .activate:        return "activate"
            case .enableStreaming: return "enable BLE streaming"
            case .readChallenge:   return "read security challenge"
            case .readBlocks:      return "read FRAM blocks"
            case .readAttribute:   return "read patch attribute"
            default:               return "[unknown: 0x\(rawValue.hex)]"
            }
        }
    }


    /// The customRequestParameters for 0xA1 are built by appending
    /// code + params (b) + usefulFunction(uid, code, secret (y))
    func nfcCommand(_ code: Subcommand) -> NFCCommand {

        var parameters = Data([code.rawValue])

        var b: [UInt8] = []
        var y: UInt16 = 0x1b6a

        if code == .enableStreaming {

            // Enables Bluetooth on Libre 2. Returns peripheral MAC address to connect to.
            // unlockCode could be any 32 bit value. The unlockCode and sensor Uid / patchInfo
            // will have also to be provided to the login function when connecting to peripheral.

            b = [
                UInt8(unlockCode & 0xFF),
                UInt8((unlockCode >> 8) & 0xFF),
                UInt8((unlockCode >> 16) & 0xFF),
                UInt8((unlockCode >> 24) & 0xFF)
            ]
            y = UInt16(patchInfo[4...5]) ^ UInt16(b[1], b[0])
        }

        if b.count > 0 {
            parameters += b
        }

        if code.rawValue < 0x20 {
            let d = Libre2.usefulFunction(id: uid, x: UInt16(code.rawValue), y: y)
            parameters += d
        }

        return NFCCommand(code: 0xA1, parameters: parameters, description: code.description)
    }
}


#if !os(watchOS)

import CoreNFC


enum IS015693Error: Int, CustomStringConvertible {
    case none                   = 0x00
    case commandNotSupported    = 0x01
    case commandNotRecognized   = 0x02
    case optionNotSupported     = 0x03
    case unknown                = 0x0f
    case blockNotAvailable      = 0x10
    case blockAlreadyLocked     = 0x11
    case contentCannotBeChanged = 0x12

    var description: String {
        switch self {
        case .none:                   return "none"
        case .commandNotSupported:    return "command not supported"
        case .commandNotRecognized:   return "command not recognized (e.g. format error)"
        case .optionNotSupported:     return "option not supported"
        case .unknown:                return "unknown"
        case .blockNotAvailable:      return "block not available (out of range, doesn’t exist)"
        case .blockAlreadyLocked:     return "block already locked -- can’t be locked again"
        case .contentCannotBeChanged: return "block locked -- content cannot be changed"
        }
    }
}


extension Error {
    var iso15693Code: Int {
        if let code = (self as NSError).userInfo[NFCISO15693TagResponseErrorKey] as? Int {
            return code
        } else {
            return 0
        }
    }
    var iso15693Description: String { IS015693Error(rawValue: self.iso15693Code)?.description ?? "[code: 0x\(self.iso15693Code.hex)]" }
}


// https://github.com/ivalkou/LibreTools/blob/master/Sources/LibreTools/NFC/NFCManager.swift


enum TaskRequest {
    case activate
    case enableStreaming
    case readFRAM
    case unlock
    case dump
}

class NFC: NSObject, NFCTagReaderSessionDelegate, Logging {

    var session: NFCTagReaderSession?
    var connectedTag: NFCISO15693Tag?
#if !targetEnvironment(macCatalyst)
    var systemInfo: NFCISO15693SystemInfo!
#endif
    var sensor: Sensor!

    var taskRequest: TaskRequest? {
        didSet {
            guard taskRequest != nil else { return }
            startSession()
        }
    }

    var main: MainDelegate!

    var isAvailable: Bool {
        return NFCTagReaderSession.readingAvailable
    }

    func startSession() {
        // execute in the .main queue because of publishing changes to main's observables
        session = NFCTagReaderSession(pollingOption: [.iso15693], delegate: self, queue: .main)
        session?.alertMessage = "Hold the top of your iPhone near the Libre sensor until the second longer vibration"
        session?.begin()
    }

    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        log("NFC: session did become active")
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if let readerError = error as? NFCReaderError {
            if readerError.code != .readerSessionInvalidationErrorUserCanceled {
                session.invalidate(errorMessage: "Connection failure: \(readerError.localizedDescription)")
                log("NFC: \(readerError.localizedDescription)")
            }
        }
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        log("NFC: did detect tags")

        guard let firstTag = tags.first else { return }
        guard case .iso15693(let tag) = firstTag else { return }

        session.alertMessage = "Scan Complete"

        if  main.app.sensor != nil {
            sensor = main.app.sensor
        } else {
            sensor = Sensor(main: main)
            main.app.sensor = sensor
        }

#if !targetEnvironment(macCatalyst)    // the async methods and Result handlers don't compile in Catalyst

        async {

            do {
                try await session.connect(to: firstTag)
                connectedTag = tag
            } catch {
                log("NFC: \(error.localizedDescription)")
                session.invalidate(errorMessage: "Connection failure: \(error.localizedDescription)")
                return
            }

            do {
                systemInfo = try await tag.systemInfo(requestFlags: .highDataRate)
                // "pop" vibration
                AudioServicesPlaySystemSound(1520)
            } catch {
                session.invalidate(errorMessage: "Error while getting system info: \(error.localizedDescription)")
                log("NFC: error while getting system info: \(error.localizedDescription)")
                return
            }

            do {
                sensor.patchInfo = Data(try await tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1, customRequestParameters: Data()))
            } catch {
                log("NFC: error while getting patch info: \(error.localizedDescription)")
            }

            // https://www.st.com/en/embedded-software/stsw-st25ios001.html#get-software

            let uid = tag.identifier.hex
            log("NFC: IC identifier: \(uid)")

            var manufacturer = "\(tag.icManufacturerCode.hex)"
            if manufacturer == "07" {
                manufacturer.append(" (Texas Instruments)")
            } else if manufacturer == "7a" {
                manufacturer.append(" (Abbott Diabetes Care)")
                sensor.type = .libre3
            }
            log("NFC: IC manufacturer code: 0x\(manufacturer)")
            log("NFC: IC serial number: \(tag.icSerialNumber.hex)")

            var rom = "RF430"
            switch tag.identifier[2] {
            case 0xA0: rom += "TAL152H Libre 1 A0"
            case 0xA4: rom += "TAL160H Libre 2 A4"
            default:   rom += " unknown"
            }
            log("NFC: \(rom) ROM")

            log(String(format: "NFC: IC reference: 0x%X", systemInfo.icReference))
            if systemInfo.applicationFamilyIdentifier != -1 {
                log(String(format: "NFC: application family id (AFI): %d", systemInfo.applicationFamilyIdentifier))
            }
            if systemInfo.dataStorageFormatIdentifier != -1 {
                log(String(format: "NFC: data storage format id: %d", systemInfo.dataStorageFormatIdentifier))
            }

            log(String(format: "NFC: memory size: %d blocks", systemInfo.totalBlocks))
            log(String(format: "NFC: block size: %d", systemInfo.blockSize))

            sensor.uid = Data(tag.identifier.reversed())
            log("NFC: sensor uid: \(sensor.uid.hex)")

            if sensor.patchInfo.count > 0 {
                log("NFC: patch info: \(sensor.patchInfo.hex)")
                log("NFC: sensor type: \(sensor.type.rawValue)\(sensor.patchInfo.hex.hasPrefix("a2") ? " (new 'A2' kind)" : "")")

                DispatchQueue.main.async {
                    self.main.settings.patchUid = self.sensor.uid
                    self.main.settings.patchInfo = self.sensor.patchInfo
                }
            }

            log("NFC: sensor serial number: \(sensor.serial)")

            if taskRequest != .none {

                /// Libre 1 memory layout:
                /// config: 0x1A00, 64    (sensor UID and calibration info)
                /// sram:   0x1C00, 512
                /// rom:    0x4400 - 0x5FFF
                /// fram lock table: 0xF840, 32
                /// fram:   0xF860, 1952

                if taskRequest == .dump {

                    do {
                        var (address, data) = try await readRaw(0x1A00, 64)
                        log(data.hexDump(header: "Config RAM (patch UID at 0x1A08):", address: address))
                        (address, data) = try await readRaw(0x1C00, 512)
                        log(data.hexDump(header: "SRAM:", address: address))
                        (address, data) = try await readRaw(0xFFAC, 36)
                        log(data.hexDump(header: "Patch table for A0-A4 E0-E2 commands:", address: address))
                        (address, data) = try await readRaw(0xF860, 43 * 8)
                        log(data.hexDump(header: "FRAM:", address: address))
                    } catch {}

                    do {
                        let (start, data) = try await read(from: 0, count: 43)
                        log(data.hexDump(header: "ISO 15693 FRAM blocks:", startingBlock: start))
                        sensor.fram = Data(data)
                        if sensor.encryptedFram.count > 0 && sensor.fram.count >= 344 {
                            log("\(sensor.fram.hexDump(header: "Decrypted FRAM:", startingBlock: 0))")
                        }
                    } catch {
                    }

                    /// count is limited to 89 with an encrypted sensor (header as first 3 blocks);
                    /// after sending the A1 1A subcommand the FRAM is decrypted in-place
                    /// and mirrored in the last 43 blocks of 89 but the max count becomes 1252
                    var count = sensor.encryptedFram.count > 0 ? 89 : 1252
                    if sensor.securityGeneration > 1 { count = 43 }

                    do {
                        let (start, data) = try await readBlocks(from: 0, count: count)

                        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)

                        let blocks = data.count / 8
                        let command = sensor.securityGeneration > 1 ? "`A1 21`" : "B0/B3"

                        log(data.hexDump(header: "\(command) command output (\(blocks) blocks):", startingBlock: start))

                        taskRequest = .none
                        session.invalidate()

                        // await main actor
                        if await main.settings.debugLevel > 0 {
                            let bytes = min(89 * 8 + 34 + 10, data.count)
                            var offset = 0
                            var i = offset + 2
                            while offset < bytes - 3 && i < bytes - 1 {
                                if UInt16(data[offset ... offset + 1]) == data[offset + 2 ... i + 1].crc16 {
                                    log("CRC matches for \(i - offset + 2) bytes at #\((offset / 8).hex) [\(offset + 2)...\(i + 1)] \(data[offset ... offset + 1].hex) = \(data[offset + 2 ... i + 1].crc16.hex)\n\(data[offset ... i + 1].hexDump(header: "\(libre2DumpMap[offset]?.1 ?? "[???]"):", address: 0))")
                                    offset = i + 2
                                    i = offset
                                }
                                i += 2
                            }
                        }

                    } catch {
                        log("NFC: \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")

                        // TODO: use defer once
                        taskRequest = .none
                        session.invalidate()
                        return
                    }

                    return
                }

                if sensor.securityGeneration > 1 {
                    var commands: [NFCCommand] = [sensor.nfcCommand(.readAttribute),
                                                  sensor.nfcCommand(.readChallenge)
                    ]

                    // await main actor
                    if await main.settings.debugLevel > 0 {
                        for block in stride(from: 0, through: 42, by: 3) {
                            var readCommand = sensor.nfcCommand(.readBlocks)
                            readCommand.parameters += Data([UInt8(block), block != 42 ? 2 : 0])
                            commands.append(readCommand)
                        }
                        // Find the only supported commands: A1, B1, B2, B4
                        //     for c in 0xA0 ... 0xBF {
                        //         commands.append(NFCCommand(code: c, description:"\(c.hex)"))
                        //     }
                    }
                    for cmd in commands {
                        log("NFC: sending \(sensor.type) command to \(cmd.description): code: 0x\(cmd.code.hex), parameters: 0x\(cmd.parameters.hex)")
                        do {
                            let output = try await tag.customCommand(requestFlags: .highDataRate, customCommandCode: cmd.code, customRequestParameters: cmd.parameters)
                            log("NFC: '\(cmd.description)' command output (\(output.count) bytes): 0x\(output.hex)")
                            if output.count == 6 { // .readAttribute
                                let state = SensorState(rawValue: output[0]) ?? .unknown
                                sensor.state = state
                                log("\(sensor.type) state: \(state.description.lowercased()) (0x\(state.rawValue.hex))")
                            }
                        } catch {
                            log("NFC: '\(cmd.description)' command error: \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
                        }
                    }

                    do {
                        defer {
                            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                            session.invalidate()    // ISO 15693 read command fails anyway
                        }

                        let (start, data) = try await readBlocks(from: 0, count: 43)
                        let blocks = data.count / 8
                        log(data.hexDump(header: "FRAM read using `A1 21` (\(blocks) blocks):", startingBlock: start))
                    } catch {
                        log("NFC: \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
                    }

                }

            libre2:
                if sensor.type == .libre2 {
                    let subCmd: Sensor.Subcommand = (taskRequest == .enableStreaming) ?
                        .enableStreaming : (taskRequest == .activate) ?
                        .activate : (taskRequest == .unlock) ?
                        .unlock :.unknown0x1c

                    // TODO
                    if subCmd == .unknown0x1c { break libre2 }    // :)

                    let currentUnlockCode = sensor.unlockCode
                    sensor.unlockCode = UInt32(await main.settings.activeSensorUnlockCode)

                    let cmd = sensor.nfcCommand(subCmd)
                    log("NFC: sending \(sensor.type) command to \(cmd.description): code: 0x\(cmd.code.hex), parameters: 0x\(cmd.parameters.hex)")

                    
                    do {
                        defer {
                            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                            taskRequest = .none
                            // session.invalidate()
                        }

                        let output = try await tag.customCommand(requestFlags: .highDataRate, customCommandCode: cmd.code, customRequestParameters: cmd.parameters)

                        log("NFC: '\(cmd.description)' command output (\(output.count) bytes): 0x\(output.hex)")

                        if subCmd == .enableStreaming && output.count == 6 {
                            log("NFC: enabled BLE streaming on \(sensor.type) \(sensor.serial) (unlock code: \(sensor.unlockCode), MAC address: \(Data(output.reversed()).hexAddress))")
                            await main.settings.activeSensorSerial = sensor.serial
                            await main.settings.activeSensorAddress = Data(output.reversed())
                            sensor.activePatchInfo = sensor.patchInfo
                            await main.settings.activeSensorPatchInfo = sensor.patchInfo
                            sensor.unlockCount = 0
                            await main.settings.activeSensorUnlockCount = 0

                            // TODO: cancel connections also before enabling streaming?
                            await main.rescan()

                        }

                        if subCmd == .activate && output.count == 4 {
                            log("NFC: after trying activating received \(output.hex) for the patch info \(sensor.patchInfo.hex)")
                            // receiving 9d081000 for a patchInfo 9d0830010000
                        }

                        if subCmd == .unlock && output.count == 0 {
                            log("NFC: FRAM should have been decrypted in-place")
                        }

                    } catch {
                        log("NFC: '\(cmd.description)' command error: \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
                        sensor.unlockCode = currentUnlockCode
                    }

                }
            }

            var blocks = 43
            if taskRequest == .readFRAM {
                if sensor.type == .libre1 {
                    blocks = 244
                }
            }

            do {
                let (start, data) = try await read(from: 0, count: blocks)
                let lastReadingDate = Date()

                // "Publishing changes from background threads is not allowed"
                DispatchQueue.main.async {
                    self.main.app.lastReadingDate = lastReadingDate
                }
                sensor.lastReadingDate = lastReadingDate
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                session.invalidate()
                log(data.hexDump(header: "NFC: did read \(data.count / 8) FRAM blocks:", startingBlock: start))
                sensor.fram = Data(data)
            } catch {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }

            if taskRequest == .readFRAM {
                sensor.detailFRAM()
                taskRequest = .none
                return
            }

            await main.parseSensorData(sensor)

            await main.status("\(sensor.type)  +  NFC")

        }

#endif    // !targetEnvironment(macCatalyst)

    }

#if !targetEnvironment(macCatalyst)    // the new Result handlers don't compile in Catalyst 14


    func read(from start: Int, count blocks: Int, requesting: Int = 3, retries: Int = 5, buffer: Data = Data(), handler: @escaping (Int, Data, Error?) -> Void) {

        var buffer = buffer
        let blockToRead = start + buffer.count / 8

        var remaining = blocks
        var requested = requesting
        var retries = retries

        // FIXME: "Feature not supported" error
        //        connectedTag?.readMultipleBlock(readConfiguration: NFCISO15693ReadMultipleBlocksConfiguration(range: NSRange(blockToRead ... blockToRead + requested - 1), chunkSize: 8, maximumRetries: 5, retryInterval: 0.1)) { data, error in
        //            log("NFC: error while reading multiple blocks #\(blockToRead.hex) - #\((blockToRead + requested - 1).hex) (\(blockToRead)-\(blockToRead + requested - 1)): \(error!) (ISO 15693 error 0x\(error!.iso15693Code.hex): \(error!.iso15693Description))")
        //        }
        //        connectedTag?.sendCustomCommand(commandConfiguration: NFCISO15693CustomCommandConfiguration(manufacturerCode: 7, customCommandCode: 0xA1, requestParameters: Data(), maximumRetries: 5, retryInterval: 0.1)) { data, error in
        //            log("NFC: custom command output: \(data.hex), error: \(error!) (ISO 15693 error 0x\(error!.iso15693Code.hex): \(error!.iso15693Description))")
        //        }

        connectedTag?.readMultipleBlocks(requestFlags: .highDataRate,
                                         blockRange: NSRange(blockToRead ... blockToRead + requested - 1)) { [self] result in
            switch result {

            case .failure(let error):
                log("NFC: error while reading multiple blocks #\(blockToRead.hex) - #\((blockToRead + requested - 1).hex) (\(blockToRead)-\(blockToRead + requested - 1)): \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
                if retries > 0 {
                    retries -= 1
                    log("NFC: retry # \(5 - retries)...")
                    usleep(100000)
                    AudioServicesPlaySystemSound(1520)    // "pop" vibration
                    read(from: start, count: remaining, requesting: requested, retries: retries, buffer: buffer) { start, data, error in handler(start, data, error) }

                } else {
                    if sensor.securityGeneration < 2 || taskRequest == .none {
                        session?.invalidate(errorMessage: "Error while reading multiple blocks: \(error.localizedDescription.localizedLowercase)")
                    }
                    handler(start, buffer, error)
                }

            case.success(let dataArray):

                for data in dataArray {
                    buffer += data
                }

                remaining -= requested

                let error: Error? = nil
                if remaining == 0 {
                    handler(start, buffer, error)

                } else {
                    if remaining < requested {
                        requested = remaining
                    }
                    read(from: start, count: remaining, requesting: requested, buffer: buffer) { start, data, error in handler(start, data, error) }
                }
            }
        }
    }


    func read(from start: Int, count blocks: Int, requesting: Int = 3, retries: Int = 5, buffer: Data = Data()) async throws -> (Int, Data) {
        try await withUnsafeThrowingContinuation { continuation in
            read(from: start, count: blocks, requesting: requesting, retries: retries, buffer: buffer) { start, data, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (start, data))
                }
            }
        }
    }


    let libre2DumpMap = [
        0x000:  (40,  "Extended header"),
        0x028:  (32,  "Extended footer"),
        0x048:  (296, "Body right-rotated by 4"),
        0x170:  (24,  "FRAM header"),
        0x188:  (296, "FRAM body"),
        0x2b0:  (24,  "FRAM footer"),
        0x2c8:  (34,  "Keys"),
        0x2ea:  (10,  "MAC Address"),
        0x26d8: (24,  "Table of enabled NFC commands")
    ]

    // 0x2580: (4, "Libre 1 backdoor")
    // 0x25c5: (7, "BLE trend offsets")
    // 0x25d0 + 1: (4 + 8, "usefulFunction() and streaming unlock keys")

    // 0c8a  CMP.W  #0xadc2, &RF13MRXF
    // 0c90  JEQ  0c96
    // 0c92  MOV.B  #0, R12
    // 0c94  RET
    // 0c96  CMP.W  #0x2175, &RF13MRXF
    // 0c9c  JNE  0c92
    // 0c9e  MOV.B  #1, R12
    // 0ca0  RET

    // function at 24e2:
    //    if (param_1 == '\x1e') {
    //      param_3 = param_3 ^ param_4;
    //    }
    //    else {
    //      param_3 = 0x1b6a;
    //    }

    // 0800: RF13MCTL
    // 0802: RF13MINT
    // 0804: RF13MIV
    // 0806: RF13MRXF
    // 0808: RF13MTXF
    // 080a: RF13MCRC
    // 080c: RF13MFIFOFL
    // 080e: RF13MWMCFG

    func readBlocks(from start: Int, count blocks: Int, requesting: Int = 3, buffer: Data = Data(), handler: @escaping (Int, Data, Error?) -> Void) {

        if sensor.securityGeneration < 1 {
            handler(start, buffer, NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "readBlocks() B3 command not supported by \(sensor.type)"]))
            return
        }

        var buffer = buffer
        let blockToRead = start + buffer.count / 8

        var remaining = blocks
        var requested = requesting

        var readCommand = NFCCommand(code: 0xB3, parameters: Data([UInt8(blockToRead & 0xFF), UInt8(blockToRead >> 8), UInt8(requested - 1)]))
        if requested == 1 {
            readCommand = NFCCommand(code: 0xB0, parameters: Data([UInt8(blockToRead & 0xFF), UInt8(blockToRead >> 8)]))
        }

        if sensor.securityGeneration > 1 {
            if blockToRead <= 255 {
                readCommand = NFCCommand(code: 0xA1, parameters: Data([0x21, UInt8(blockToRead), UInt8(requested - 1)]))
            }
        }

        if buffer.count == 0 { debugLog("NFC: sending \(readCommand.code.hex) 07 \(readCommand.parameters.hex) command (\(sensor.type) read blocks)") }

        connectedTag?.customCommand(requestFlags: .highDataRate, customCommandCode: readCommand.code, customRequestParameters: readCommand.parameters) { [self] result in

            switch result {

            case .failure(let error):
                if requested == 1 {
                    log("NFC: error while reading block #\(blockToRead.hex): \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
                } else {
                    log("NFC: error while reading multiple blocks #\(blockToRead.hex) - #\((blockToRead + requested - 1).hex) (\(blockToRead)-\(blockToRead + requested - 1)): \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
                }

                handler(start, buffer, error)

            case.success(let data):
                if sensor.securityGeneration < 2 {
                    buffer += data
                } else {
                    buffer += data.suffix(data.count - 8)    // skip leading 0xA5 dummy bytes
                }
                remaining -= requested

                let error: Error? = nil
                if remaining == 0 {
                    handler(start, buffer, error)
                } else {
                    if remaining < requested {
                        requested = remaining
                    }
                    readBlocks(from: start, count: remaining, requesting: requested, buffer: buffer) { start, data, error in handler(start, data, error) }
                }
            }
        }
    }


    func readBlocks(from start: Int, count blocks: Int, requesting: Int = 3, buffer: Data = Data()) async throws -> (Int, Data) {

        if sensor.securityGeneration < 1 {
            debugLog("readBlocks() B3 command not supported by \(sensor.type)")
            throw NFCError.commandNotSupported
        }

        var buffer = buffer
        let blockToRead = start + buffer.count / 8

        var remaining = blocks
        var requested = requesting

        var readCommand = NFCCommand(code: 0xB3, parameters: Data([UInt8(blockToRead & 0xFF), UInt8(blockToRead >> 8), UInt8(requested - 1)]))
        if requested == 1 {
            readCommand = NFCCommand(code: 0xB0, parameters: Data([UInt8(blockToRead & 0xFF), UInt8(blockToRead >> 8)]))
        }

        if sensor.securityGeneration > 1 {
            if blockToRead <= 255 {
                readCommand = NFCCommand(code: 0xA1, parameters: Data([0x21, UInt8(blockToRead), UInt8(requested - 1)]))
            }
        }

        if buffer.count == 0 { debugLog("NFC: sending \(readCommand.code.hex) 07 \(readCommand.parameters.hex) command (\(sensor.type) read blocks)") }

        do {
            let output = try await connectedTag?.customCommand(requestFlags: .highDataRate, customCommandCode: readCommand.code, customRequestParameters: readCommand.parameters)
            let data = Data(output!)

            if sensor.securityGeneration < 2 {
                buffer += data
            } else {
                buffer += data.suffix(data.count - 8)    // skip leading 0xA5 dummy bytes
            }
            remaining -= requested

            if remaining != 0 {
                if remaining < requested {
                    requested = remaining
                }
                (_, buffer) = try await readBlocks(from: start, count: remaining, requesting: requested, buffer: buffer)
            }
        } catch {
            if requested == 1 {
                log("NFC: error while reading block #\(blockToRead.hex): \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
            } else {
                log("NFC: error while reading multiple blocks #\(blockToRead.hex) - #\((blockToRead + requested - 1).hex) (\(blockToRead)-\(blockToRead + requested - 1)): \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
            }
            throw NFCError.readBlocks
        }

        return (start, buffer)
    }


    func readBlocks(from start: Int, count blocks: Int, requesting: Int = 3) async throws -> (Int, Data) {

        if sensor.securityGeneration < 1 {
            debugLog("readBlocks() B3 command not supported by \(sensor.type)")
            throw NFCError.commandNotSupported
        }

        var buffer = Data()

        var remaining = blocks
        var requested = requesting

        while remaining > 0 {

            let blockToRead = start + buffer.count / 8

            var readCommand = NFCCommand(code: 0xB3, parameters: Data([UInt8(blockToRead & 0xFF), UInt8(blockToRead >> 8), UInt8(requested - 1)]))
            if requested == 1 {
                readCommand = NFCCommand(code: 0xB0, parameters: Data([UInt8(blockToRead & 0xFF), UInt8(blockToRead >> 8)]))
            }

            if sensor.securityGeneration > 1 {
                if blockToRead <= 255 {
                    readCommand = NFCCommand(code: 0xA1, parameters: Data([0x21, UInt8(blockToRead), UInt8(requested - 1)]))
                }
            }

            if buffer.count == 0 { debugLog("NFC: sending \(readCommand.code.hex) 07 \(readCommand.parameters.hex) command (\(sensor.type) read blocks)") }

            do {
                let output = try await connectedTag?.customCommand(requestFlags: .highDataRate, customCommandCode: readCommand.code, customRequestParameters: readCommand.parameters)
                let data = Data(output!)

                if sensor.securityGeneration < 2 {
                    buffer += data
                } else {
                    buffer += data.suffix(data.count - 8)    // skip leading 0xA5 dummy bytes
                }
                remaining -= requested

                if remaining != 0 {
                    if remaining < requested {
                        requested = remaining
                    }
                }
            } catch {
                log(buffer.hexDump(header: "\(sensor.securityGeneration > 1 ? "`A1 21`" : "B0/B3") command output (\(buffer.count/8) blocks):", startingBlock: start))
                if requested == 1 {
                    log("NFC: error while reading block #\(blockToRead.hex): \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
                } else {
                    log("NFC: error while reading multiple blocks #\(blockToRead.hex) - #\((blockToRead + requested - 1).hex) (\(blockToRead)-\(blockToRead + requested - 1)): \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
                }
                throw NFCError.readBlocks
            }
        }

        return (start, buffer)
    }


    // Libre 1 only

    func readRaw(_ address: Int, _ bytes: Int, buffer: Data = Data(), handler: @escaping (Int, Data, Error?) -> Void) {

        if sensor.type != .libre1 {
            handler(address, buffer, NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "readRaw() A3 command not supported by \(sensor.type)"]))
            return
        }

        var buffer = buffer
        let addressToRead = address + buffer.count

        var remainingBytes = bytes
        let bytesToRead = remainingBytes > 24 ? 24 : bytes

        var remainingWords = bytes / 2
        if bytes % 2 == 1 || ( bytes % 2 == 0 && addressToRead % 2 == 1 ) { remainingWords += 1 }
        let wordsToRead = remainingWords > 12 ? 12 : remainingWords    // real limit is 15

        let readRawCommand = NFCCommand(code: 0xA3, parameters: sensor.backdoor + [UInt8(addressToRead & 0xFF), UInt8(addressToRead >> 8), UInt8(wordsToRead)])

        if buffer.count == 0 { debugLog("NFC: sending \(readRawCommand.code.hex) 07 \(readRawCommand.parameters.hex) command (\(sensor.type) read raw)") }

        connectedTag?.customCommand(requestFlags: .highDataRate, customCommandCode: readRawCommand.code, customRequestParameters: readRawCommand.parameters) { [self] result in

            switch result {

            case .failure(let error):
                debugLog("NFC: error while reading \(wordsToRead) words at raw memory 0x\(addressToRead.hex): \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
                handler(address, buffer, error)

            case.success(var data):

                if addressToRead % 2 == 1 { data = data.subdata(in: 1 ..< data.count) }
                if data.count - bytesToRead == 1 { data = data.subdata(in: 0 ..< data.count - 1) }

                buffer += data
                remainingBytes -= data.count

                let error: Error? = nil
                if remainingBytes == 0 {
                    handler(address, buffer, error)
                } else {
                    readRaw(address, remainingBytes, buffer: buffer) { address, data, error in handler(address, data, error) }
                }
            }
        }
    }


    func readRaw(_ address: Int, _ bytes: Int, buffer: Data = Data()) async throws -> (Int, Data) {

        if sensor.type != .libre1 {
            debugLog("readRaw() A3 command not supported by \(sensor.type)")
            throw NFCError.commandNotSupported
        }

        var buffer = buffer
        let addressToRead = address + buffer.count

        var remainingBytes = bytes
        let bytesToRead = remainingBytes > 24 ? 24 : bytes

        var remainingWords = bytes / 2
        if bytes % 2 == 1 || ( bytes % 2 == 0 && addressToRead % 2 == 1 ) { remainingWords += 1 }
        let wordsToRead = remainingWords > 12 ? 12 : remainingWords    // real limit is 15

        let readRawCommand = NFCCommand(code: 0xA3, parameters: sensor.backdoor + [UInt8(addressToRead & 0xFF), UInt8(addressToRead >> 8), UInt8(wordsToRead)])

        if buffer.count == 0 { debugLog("NFC: sending \(readRawCommand.code.hex) 07 \(readRawCommand.parameters.hex) command (\(sensor.type) read raw)") }

        do {
            let output = try await connectedTag?.customCommand(requestFlags: .highDataRate, customCommandCode: readRawCommand.code, customRequestParameters: readRawCommand.parameters)
            var data = Data(output!)

            if addressToRead % 2 == 1 { data = data.subdata(in: 1 ..< data.count) }
            if data.count - bytesToRead == 1 { data = data.subdata(in: 0 ..< data.count - 1) }

            buffer += data
            remainingBytes -= data.count

            if remainingBytes != 0 {
                (_, buffer) = try await readRaw(address, remainingBytes, buffer: buffer)
            }
        } catch {
            debugLog("NFC: error while reading \(wordsToRead) words at raw memory 0x\(addressToRead.hex): \(error.localizedDescription) (ISO 15693 error 0x\(error.iso15693Code.hex): \(error.iso15693Description))")
            throw NFCError.customCommandError
        }

        return (address, buffer)

    }


    // Libre 1 only: overwrite mirrored FRAM blocks

    /// To enable E0 reset command: writeRaw(0xFFB8, Data([0xE0, 0x00]))
    /// To disable E0 again: writeRaw(0xFFB8, Data([0xAB, 0xAB]))
    /// Both require recomputing and overwriting the commands CRC for fram[43 * 8 + 2 ..< (244 - 6) * 8])

    func writeRaw(_ address: Int, _ data: Data, handler: @escaping (Int, Data, Error?) -> Void) {

        if sensor.type != .libre1 {
            handler(address, Data(), NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "writeRaw() not supported by \(sensor.type)"]))
            return
        }

        // Unlock
        debugLog("NFC: sending a4 07 \(sensor.backdoor.hex) command (\(sensor.type) unlock)")
        connectedTag?.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA4, customRequestParameters: sensor.backdoor) { [self] result in

            switch result {

            case .failure(let commandError):
                debugLog("NFC: unlock command error: \(commandError.localizedDescription)")

            case.success(let output):
                debugLog("NFC: unlock command output: 0x\(output.hex)")
            }

            let addressToRead = (address / 8) * 8
            let startOffset = address % 8
            let endAddressToRead = ((address + data.count - 1) / 8) * 8 + 7
            let blocksToRead = (endAddressToRead - addressToRead) / 8 + 1

            readRaw(addressToRead, blocksToRead * 8) {

                readAddress, readData, error in

                var msg = error?.localizedDescription ?? readData.hexDump(header: "NFC: blocks to overwrite:", address: readAddress)

                if error != nil {
                    handler(address, data, error)
                    return
                }

                var bytesToWrite = readData
                bytesToWrite.replaceSubrange(startOffset ..< startOffset + data.count, with: data)
                msg += "\(bytesToWrite.hexDump(header: "\nwith blocks:", address: addressToRead))"
                debugLog(msg)

                let startBlock = addressToRead / 8
                let blocks = bytesToWrite.count / 8

                if address >= 0xF860 {    // write to FRAM blocks

                    let requestBlocks = 2    // 3 doesn't work

                    let requests = Int(ceil(Double(blocks) / Double(requestBlocks)))
                    let remainder = blocks % requestBlocks
                    var blocksToWrite = [Data](repeating: Data(), count: blocks)

                    for i in 0 ..< blocks {
                        blocksToWrite[i] = Data(bytesToWrite[i * 8 ... i * 8 + 7])
                    }

                    for i in 0 ..< requests {

                        let startIndex = startBlock - 0xF860 / 8 + i * requestBlocks
                        let endIndex = startIndex + (i == requests - 1 ? (remainder == 0 ? requestBlocks : remainder) : requestBlocks) - (requestBlocks > 1 ? 1 : 0)
                        let blockRange = NSRange(startIndex ... endIndex)

                        var dataBlocks = [Data]()
                        for j in startIndex ... endIndex { dataBlocks.append(blocksToWrite[j - startIndex]) }

                        connectedTag?.writeMultipleBlocks(requestFlags: .highDataRate, blockRange: blockRange, dataBlocks: dataBlocks) { [self]

                            error in

                            if error != nil {
                                log("NFC: error while writing multiple blocks 0x\(startIndex.hex)-0x\(endIndex.hex) \(dataBlocks.reduce("", { $0 + $1.hex })) at 0x\(((startBlock + i * requestBlocks) * 8).hex): \(error!.localizedDescription)")
                                if i != requests - 1 { return }

                            } else {
                                debugLog("NFC: wrote blocks 0x\(startIndex.hex) - 0x\(endIndex.hex) \(dataBlocks.reduce("", { $0 + $1.hex })) at 0x\(((startBlock + i * requestBlocks) * 8).hex)")
                            }

                            if i == requests - 1 {

                                // Lock
                                connectedTag?.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA2, customRequestParameters: sensor.backdoor) { result in

                                    var error: Error? = nil

                                    switch result {

                                    case .failure(let commandError):
                                        debugLog("NFC: lock command error: \(commandError.localizedDescription)")
                                        error = commandError

                                    case.success(let output):
                                        debugLog("NFC: lock command output: 0x\(output.hex)")
                                    }

                                    handler(address, data, error)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

#endif    // !targetEnvironment(macCatalyst)

}

#endif    // !os(watchOS)
