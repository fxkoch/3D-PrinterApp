import Foundation
@testable import PrinterKit
import XCTest

final class AnycubicTests: XCTestCase {
    func testMD5Vectors() {
        XCTAssertEqual(LANCrypto.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(LANCrypto.md5Hex("The quick brown fox jumps over the lazy dog"), "9e107d9d372bb6826bd81d3542a419d6")
        XCTAssertEqual(LANCrypto.md5Hex(String(repeating: "a", count: 100)), "36a92cc94a9e0fa21f625f8bfb007adf")
    }

    func testAESKnownVector() throws {
        // FIPS-197 appendix C.1
        let key: [UInt8] = Array(0..<16)
        let plain: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        let expected: [UInt8] = [0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a]
        let keys = LANCrypto.expandKey(key)
        XCTAssertEqual(LANCrypto.encryptBlock(plain, roundKeys: keys), expected)
        XCTAssertEqual(LANCrypto.decryptBlock(expected, roundKeys: keys), plain)
        // CBC + PKCS#7 round trip
        let iv = Array("1234567890abcdef".utf8)
        let msg = Array(#"{"broker":"mqtts://10.0.0.5:9883"}"#.utf8)
        let enc = LANCrypto.aes128CBCEncrypt(msg, key: key, iv: iv)
        XCTAssertEqual(try LANCrypto.aes128CBCDecrypt(enc, key: key, iv: iv), msg)
    }

    func testHandshakeParsing() throws {
        let token = "ABCDEFGHIJKLMNOPqrstuvwxyz012345"
        let d = try AnycubicHandshake.parseDiscovery(["token": token, "ctrlInfoUrl": "http://10.0.0.5:18910/ctrl",
                                                      "modelId": 20025, "ctrlType": "lan", "modelName": "Anycubic Kobra S1"])
        XCTAssertEqual(d.modelID, 20025)
        XCTAssertThrowsError(try AnycubicHandshake.parseDiscovery(["ctrlType": "cloud"])) {
            XCTAssertEqual($0 as? AnycubicHandshake.HandshakeError, .lanModeOff)
        }
        let url = AnycubicHandshake.controlURL(d, ts: 1700000000000, nonce: "abc123", did: "X")
        let expectedSign = LANCrypto.md5Hex(LANCrypto.md5Hex("ABCDEFGHIJKLMNOP") + "1700000000000abc123")
        XCTAssertEqual(url, "http://10.0.0.5:18910/ctrl?ts=1700000000000&nonce=abc123&sign=\(expectedSign)&did=X")

        // Build an encrypted credential blob the way the printer does.
        let creds = #"{"broker":"mqtts://10.0.0.5:9883","username":"u","password":"p","deviceId":"dev42"}"#
        let ivSource = "localtoken"
        var iv = Array(ivSource.utf8); while iv.count < 16 { iv.append(0) }
        let cipher = LANCrypto.aes128CBCEncrypt(Array(creds.utf8), key: Array(token.utf8.dropFirst(16)), iv: iv)
        let response: [String: Any] = ["code": 200, "data": ["token": ivSource, "info": Data(cipher).base64EncodedString()]]
        let c = try AnycubicHandshake.parseControlResponse(response, discovery: d)
        XCTAssertEqual(c, AnycubicHandshake.Credentials(host: "10.0.0.5", port: 9883, username: "u", password: "p",
                                                         deviceID: "dev42", modelID: 20025, modelName: "Anycubic Kobra S1"))
        XCTAssertThrowsError(try AnycubicHandshake.parseControlResponse(["code": 401, "message": "denied"], discovery: d))
    }

    func testMQTTCodec() {
        let connect = MQTTCodec.connect(clientID: "c", username: "u", password: "p", keepAlive: 60)
        XCTAssertEqual(connect.first, 0x10)
        XCTAssertEqual(Array(connect.prefix(10)), [0x10, 19, 0, 4, 0x4d, 0x51, 0x54, 0x54, 4, 0xC2])

        var decoder = MQTTCodec.Decoder()
        let topic = "anycubic/x/info/report"
        let big = Data(repeating: 0x41, count: 300) // forces a two-byte length
        let publish = MQTTCodec.publish(topic: topic, payload: big)
        decoder.append(Data([0x20, 0x02, 0x00, 0x00]) + publish.prefix(10))
        XCTAssertEqual(decoder.next(), .connAck(returnCode: 0))
        XCTAssertNil(decoder.next(), "incomplete packet waits for more bytes")
        decoder.append(publish.dropFirst(10) + Data([0xD0, 0x00]))
        XCTAssertEqual(decoder.next(), .publish(topic: topic, payload: big, qos: 0, packetID: nil))
        XCTAssertEqual(decoder.next(), .pingResp)
        XCTAssertNil(decoder.next())
    }

    func testStartPayloadHasACEMapping() throws {
        let p = AnycubicHandshake.startPayload(fileName: "a.gcode", md5: "x", size: 10,
                                               mapping: [SlotMapping(tool: 0, slot: 2, materialType: "PLA", color: [255, 0, 0])],
                                               msgID: "m", now: 1)
        let body = try JSONSerialization.data(withJSONObject: p)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        let ams = try XCTUnwrap(data["ams_settings"] as? [String: Any])
        let map = try XCTUnwrap((ams["ams_box_mapping"] as? [[String: Any]])?.first)
        XCTAssertEqual(map["ams_index"] as? Int, 2)
        XCTAssertEqual(map["paint_color"] as? [Int], [255, 0, 0, 255])
        XCTAssertEqual(json["action"] as? String, "start")
    }

    func testAnycubicReportsUpdateStatus() {
        var s = PrinterStatus()
        s.applyAnycubic(type: "info", data: [
            "state": "busy", "version": "2.7.2.7",
            "temp": ["curr_nozzle_temp": 219, "target_nozzle_temp": 220, "curr_hotbed_temp": 59, "target_hotbed_temp": 60,
                     "curr_chamber_temp": 31],
            "project": ["progress": 42, "curr_layer": 10, "total_layers": 100, "remain_time": 30, "print_time": 600,
                        "filename": "cube.gcode", "state": "printing", "pause": 0, "taskid": 7],
            "urls": ["rtspUrl": "http://10.0.0.5:18088/flv"],
        ])
        XCTAssertEqual(s.state, .printing)
        XCTAssertEqual(s.progress, 0.42, accuracy: 1e-9)
        XCTAssertEqual(s.remainingSeconds, 1800)
        XCTAssertEqual(s.tools.first?.target, 220)
        XCTAssertEqual(s.chamber?.temperature, 31)
        XCTAssertEqual(s.taskID, "7")
        s.applyAnycubic(type: "multiColorBox", data: ["multi_color_box": [[
            "id": 0, "temp": 35, "humidity": 24, "loaded_slot": 1,
            "drying_status": ["status": 0, "target_temp": 0, "duration": 0, "remain_time": 0],
            "slots": [["index": 0, "type": "PLA", "color": [255, 0, 0], "sku": "X"], ["index": 1, "type": "PETG", "color": [0, 0, 255]],
                      ["index": 2, "type": "", "color": [0, 0, 0]]],
        ]]])
        XCTAssertEqual(s.filamentBox?.humidity, 24)
        XCTAssertEqual(s.filamentBox?.activeSlot, 1)
        XCTAssertEqual(s.filaments.count, 3)
        XCTAssertEqual(s.filaments[0].color, "#FF0000")
        XCTAssertEqual(s.filaments[1].type, "PETG")
        XCTAssertFalse(s.filaments[2].present)
        s.applyAnycubic(type: "info", data: ["state": "free", "last_project": ["state": "finished", "filename": "cube.gcode"]])
        XCTAssertEqual(s.state, .complete)
        s.applyAnycubic(type: "light", data: ["type": 2, "status": 1, "brightness": 100])
        XCTAssertEqual(s.lightOn, true)
    }

    func testMoonrakerCalibrationParsing() {
        let cal = MoonrakerClient.parseCalibration([
            "bed_mesh": ["profile_name": "default", "mesh_min": [3, 3], "mesh_max": [267, 267],
                         "probed_matrix": [[0.01, -0.02], [0.03, 0.0]]],
            "gcode_move": ["homing_origin": [0, 0, -0.07, 0]],
            "extruder": ["pressure_advance": 0.035],
            "configfile": ["settings": ["input_shaper": ["shaper_type_x": "mzv", "shaper_freq_x": 52.4]]],
        ])
        XCTAssertEqual(cal.bedMesh?.points.count, 2)
        XCTAssertEqual(cal.bedMesh?.range ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertEqual(cal.zOffset, -0.07)
        XCTAssertEqual(cal.pressureAdvance["extruder"], 0.035)
        XCTAssertEqual(cal.inputShaper["shaper_type_x"], "mzv")
    }

    func testConnectionDecodingDefaults() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"U1","host":"10.0.0.2"}"#
        let c = try JSONDecoder().decode(PrinterConnection.self, from: Data(old.utf8))
        XCTAssertEqual(c.kind, .moonraker)
        XCTAssertEqual(c.model, "snapmakerU1")
        XCTAssertEqual(PrinterConnection(name: "K", host: "http://10.0.0.9:7125").hostOnly, "10.0.0.9")
    }
}
