import Foundation


class Gen2 {

    static let GEN2_CMD_DECRYPT_BLE_DATA = 773
    static let GEN2_CMD_DECRYPT_NFC_DATA = 12545
    static let GEN2_CMD_DECRYPT_NFC_STREAM = 6520
    static let GEN2_CMD_END_SESSION = 37400
    static let GEN2_CMD_GET_AUTH_CONTEXT = 28960
    static let GEN2_CMD_GET_BLE_AUTHENTICATED_CMD = 6505
    static let GEN2_CMD_GET_CREATE_SESSION = 29465
    static let GEN2_CMD_GET_NFC_AUTHENTICATED_CMD = 6440
    static let GEN2_CMD_GET_PVALUES = 6145
    static let GEN2_CMD_INIT_LIB = 0
    static let GEN2_CMD_PERFORM_SENSOR_CONTEXT_CRYPTO = 18712
    static let GEN2_CMD_VERIFY_RESPONSE = 22321


    enum Gen2Error: Int, Error {
        case GEN2_SEC_ERROR_INIT            = -1
        case GEN2_SEC_ERROR_CMD             = -2
        case GEN2_SEC_ERROR_KDF             = -9
        case GEN2_SEC_ERROR_RESPONSE_SIZE   = -10
        case GEN2_ERROR_AUTH_CONTEXT        = -11
        case GEN2_ERROR_PRNG_ERROR          = -12
        case GEN2_ERROR_KEY_NOT_FOUND       = -13
        case GEN2_ERROR_SKB_ERROR           = -14
        case GEN2_ERROR_INVALID_RESPONSE    = -15
        case GEN2_ERROR_INSUFFICIENT_BUFFER = -16
        case GEN2_ERROR_CRC_MISMATCH        = -17
        case GEN2_ERROR_MISSING_NATIVE      = -98
        case GEN2_ERROR_PROCESS_ERROR       = -99
    }

    struct Result {
        let data: Data?
        let error: Gen2Error?
    }


    static func p1(command: Int, _ i2: Int, _ d1: Data?, _ d2: Data?) -> Int {
        return 0
    }

    static func p2(command: Int, p1: Int, _ d1: Data, _ d2: Data?) -> Result {
        return Result(data: Data(), error: nil)
    }


    static func createSecureSession(context: Int) -> Int {
        return p1(command: GEN2_CMD_END_SESSION, context, nil, nil)
    }

    static func endSession(context: Int) -> Int {
        return p1(command: GEN2_CMD_END_SESSION, context, nil, nil)
    }

    static func getNfcAuthenticatedCommandBLE(command: Int, uid: SensorUid, challenge: Data, output: inout Data) -> Int {
        let authContext = p1(command: GEN2_CMD_GET_AUTH_CONTEXT, 0, uid, nil)
        if authContext < 0 {
            return authContext
        }
        let commandArg = Data([1, UInt8(command)])
        let result = p2(command: GEN2_CMD_GET_BLE_AUTHENTICATED_CMD, p1: authContext, commandArg, challenge)
        if result.data == nil {
            _ = Gen2.endSession(context: authContext)
            return result.error != nil ? result.error!.rawValue : Gen2Error.GEN2_ERROR_PROCESS_ERROR.rawValue
        }
        output = result.data!
        return authContext
    }

    static func getNfcAuthenticatedCommandNfc(command: Int, uid: SensorUid, challenge: Data, output: inout Data) -> Int {
        let authContext = p1(command: GEN2_CMD_GET_AUTH_CONTEXT, 0, uid, nil)
        if authContext < 0 {
            return authContext
        }
        let commandArg = Data([0, UInt8(command)])
        let result = p2(command: GEN2_CMD_GET_NFC_AUTHENTICATED_CMD, p1: authContext, commandArg, challenge)
        if result.data == nil {
            _ = Gen2.endSession(context: authContext)
            return result.error != nil ? result.error!.rawValue : Gen2Error.GEN2_ERROR_PROCESS_ERROR.rawValue
        }
        output = result.data!
        output[0 ... 3] = Data([2, 0xA1, 7, UInt8(command)])
        return authContext
    }

    static func decrytpNfcData(p1: Int, fromBlock: Int, count: Int, data: Data) -> Result {
        return p2(command: GEN2_CMD_DECRYPT_NFC_STREAM, p1: p1, Data([UInt8(fromBlock), UInt8(count)]), data)
    }

    static func decryptStreamingData(p1: Int, data: Data) -> Result {
        return p2(command: GEN2_CMD_DECRYPT_BLE_DATA, p1: p1, data, nil)
    }

}
