import Foundation


// https://github.com/ivalkou/LibreTools/blob/master/Sources/LibreTools/NFC/NFCManager.swift


#if !os(watchOS) && !targetEnvironment(macCatalyst)

import CoreNFC

extension NFC {

    func reset() async throws {

        if sensor.type != .libre1 {
            debugLog("E0 reset command not supported by \(sensor.type)")
            throw NFCError.commandNotSupported
        }

        let (commandsFramAddress, commmandsFram) = try await readRaw(0xF860 + 43 * 8, 195 * 8)

        let e0Offset = 0xFFB6 - commandsFramAddress
        let a1Offset = 0xFFC6 - commandsFramAddress
        let e0Address = UInt16(commmandsFram[e0Offset ... e0Offset + 1])
        let a1Address = UInt16(commmandsFram[a1Offset ... a1Offset + 1])

        debugLog("E0 and A1 commands' addresses: \(e0Address.hex) \(a1Address.hex) (should be fbae and f9ba)")

        let originalCRC = crc16(commmandsFram[2 ..< 195 * 8])
        debugLog("Commands section CRC: \(UInt16(commmandsFram[0...1]).hex), computed: \(originalCRC.hex) (should be 429e or f9ae for a Libre 1 A2)")

        var patchedFram = Data(commmandsFram)
        patchedFram[a1Offset ... a1Offset + 1] = e0Address.data
        let patchedCRC = crc16(patchedFram[2 ..< 195 * 8])
        patchedFram[0 ... 1] = patchedCRC.data

        debugLog("CRC after replacing the A1 command address with E0: \(patchedCRC.hex) (should be 6e01 or d531 for a Libre 1 A2)")

        do {
            try await writeRaw(commandsFramAddress + a1Offset, e0Address.data)
            try await writeRaw(commandsFramAddress, patchedCRC.data)
            try await send(sensor.getPatchInfoCommand)
            try await writeRaw(commandsFramAddress + a1Offset, a1Address.data)
            try await writeRaw(commandsFramAddress, originalCRC.data)

            let (start, data) = try await read(from: 0, count: 43)
            log(data.hexDump(header: "NFC: did reset FRAM:", startingBlock: start))
            sensor.fram = Data(data)
        } catch {
        }

        // TODO: manage errors and verify integrity

    }


    func prolong() async throws {

        if sensor.type != .libre1 {
            debugLog("FRAM overwriting not supported by \(sensor.type)")
            throw NFCError.commandNotSupported
        }

        let (footerAddress, footerFram) = try await readRaw(0xF860 + 40 * 8, 3 * 8)

        let maxAgeOffset = 6
        let maxLife = Int(footerFram[maxAgeOffset + 1]) << 8 + Int(footerFram[maxAgeOffset])
        log("\(sensor.type) current maximum age: \(maxLife) minutes (\(maxLife.formattedInterval))")

        var patchedFram = Data(footerFram)
        patchedFram[maxAgeOffset ... maxAgeOffset + 1] = Data([0xFF, 0xFF])
        let patchedCRC = crc16(patchedFram[2 ..< 3 * 8])
        patchedFram[0 ... 1] = patchedCRC.data

        do {
            try await writeRaw(footerAddress + maxAgeOffset, patchedFram[maxAgeOffset ... maxAgeOffset + 1])
            try await writeRaw(footerAddress, patchedCRC.data)

            let (_, data) = try await read(from: 0, count: 43)
            log(Data(data.suffix(3 * 8)).hexDump(header: "NFC: did overwite FRAM footer:", startingBlock: 40))
            sensor.fram = Data(data)
        } catch {
        }

        // TODO: manage errors and verify integrity

    }

}

#endif    // !os(watchOS) && !targetEnvironment(macCatalyst)
