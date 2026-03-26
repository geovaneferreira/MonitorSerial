//
//  SerialPortService.swift
//  MonitorSerial
//
//  Created by Codex on 26/03/26.
//

import Foundation
import SwiftUI
import Combine
import IOKit
import IOKit.serial
import Darwin

struct SerialPortDescriptor: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let displayName: String
}

enum PayloadDisplayMode: String, CaseIterable, Identifiable, Codable, Equatable {
    case ascii
    case hex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ascii:
            return "ASCII"
        case .hex:
            return "HEX"
        }
    }
}

enum SerialParity: String, CaseIterable, Identifiable {
    case none
    case even
    case odd

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:
            return "Nenhuma"
        case .even:
            return "Par"
        case .odd:
            return "Ímpar"
        }
    }
}

enum SerialDirection: Equatable {
    case incoming
    case outgoing
    case event

    var color: Color {
        switch self {
        case .incoming:
            return Color(red: 0.14, green: 0.78, blue: 0.50)
        case .outgoing:
            return Color(red: 0.97, green: 0.66, blue: 0.16)
        case .event:
            return Color(red: 0.48, green: 0.66, blue: 1.0)
        }
    }

    var symbol: String {
        switch self {
        case .incoming:
            return "RX"
        case .outgoing:
            return "TX"
        case .event:
            return "•"
        }
    }
}

struct SerialLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let direction: SerialDirection
    let bytes: Data
    let message: String?

    init(timestamp: Date = .now, direction: SerialDirection, bytes: Data = Data(), message: String? = nil) {
        self.timestamp = timestamp
        self.direction = direction
        self.bytes = bytes
        self.message = message
    }

    func payloadText(mode: PayloadDisplayMode) -> String {
        if let message {
            return message
        }

        switch mode {
        case .ascii:
            let decoded = String(decoding: bytes, as: UTF8.self)
            return decoded.isEmpty ? "<vazio>" : decoded.replacingOccurrences(of: "\0", with: "·")
        case .hex:
            return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }
}

struct SavedCommand: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let payload: String
    let mode: PayloadDisplayMode

    init(id: UUID = UUID(), title: String, payload: String, mode: PayloadDisplayMode) {
        self.id = id
        self.title = title
        self.payload = payload
        self.mode = mode
    }

    static let samples: [SavedCommand] = [
        SavedCommand(title: "Ping módulo", payload: "AT", mode: .ascii),
        SavedCommand(title: "Ler status", payload: "7E 01 03 01 01 34 00 01", mode: .hex),
        SavedCommand(title: "Reset", payload: "7E 01 03 01 01 35 00 01", mode: .hex)
    ]
}

@MainActor
final class SerialPortService: ObservableObject {
    static let supportedBaudRates = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400]
    private static let maxLogEntries = 1500

    @Published var availablePorts: [SerialPortDescriptor] = []
    @Published var selectedPortPath: String?
    @Published var selectedBaudRate = 115200
    @Published var dataBits = 8
    @Published var stopBits = 1
    @Published var parity: SerialParity = .none
    @Published var logEntries: [SerialLogEntry] = []
    @Published var errorMessage: String?
    @Published var isConnected = false
    @Published var activePortName: String?
    @Published var totalReceivedBytes = 0
    @Published var totalSentBytes = 0

    private var fileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "monitorserial.serial.io", qos: .userInitiated)
    private var pendingIncomingData = Data()
    private var pendingFlushTask: Task<Void, Never>?

    var statusSummary: String {
        if isConnected {
            return "\(activePortName ?? "Porta serial") conectada em \(selectedBaudRate) bps"
        }
        return "Pronto para conectar e monitorar a UART"
    }

    var mergedEntries: [SerialLogEntry] {
        guard !logEntries.isEmpty else { return [] }

        var merged: [SerialLogEntry] = []
        var pending: SerialLogEntry?

        for entry in logEntries {
            if let current = pending,
               current.direction == entry.direction,
               current.message == nil,
               entry.message == nil {
                let combined = current.bytes + entry.bytes
                pending = SerialLogEntry(timestamp: current.timestamp, direction: current.direction, bytes: combined)
            } else {
                if let current = pending {
                    merged.append(current)
                }
                pending = entry
            }
        }

        if let pending {
            merged.append(pending)
        }

        return merged
    }

    func refreshPorts() {
        availablePorts = Self.discoverSerialPorts()
        if selectedPortPath == nil {
            selectedPortPath = availablePorts.first?.path
        } else if !availablePorts.contains(where: { $0.path == selectedPortPath }) {
            selectedPortPath = availablePorts.first?.path
        }
    }

    func openConnection() {
        guard let selectedPortPath else {
            errorMessage = "Selecione uma porta serial antes de abrir a conexão."
            return
        }

        closeConnection()

        let descriptor = open(selectedPortPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            errorMessage = "Não foi possível abrir \(selectedPortPath)."
            return
        }

        do {
            try configurePort(descriptor)
            fileDescriptor = descriptor
            activePortName = URL(fileURLWithPath: selectedPortPath).lastPathComponent
            isConnected = true
            appendEvent("Conectado em \(activePortName ?? selectedPortPath) com \(selectedBaudRate) bps")
            startReadLoop()
        } catch {
            close(descriptor)
            fileDescriptor = -1
            errorMessage = error.localizedDescription
        }
    }

    func closeConnection() {
        readSource?.cancel()
        readSource = nil
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        pendingIncomingData.removeAll(keepingCapacity: false)

        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        if isConnected {
            appendEvent("Conexão encerrada")
        }

        isConnected = false
        activePortName = nil
    }

    func send(_ payload: String, mode: PayloadDisplayMode) {
        guard fileDescriptor >= 0 else {
            errorMessage = "Abra a conexão antes de enviar comandos."
            return
        }

        let bytesToSend: Data
        switch mode {
        case .ascii:
            bytesToSend = Data(payload.utf8)
        case .hex:
            guard let decoded = Self.decodeHexString(payload) else {
                errorMessage = "Payload HEX inválido. Use pares como 7E 01 0A."
                return
            }
            bytesToSend = decoded
        }

        bytesToSend.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = write(fileDescriptor, baseAddress, buffer.count)
        }

        totalSentBytes += bytesToSend.count
        appendLogEntry(SerialLogEntry(direction: .outgoing, bytes: bytesToSend))
    }

    func clearLog() {
        logEntries.removeAll()
        totalReceivedBytes = 0
        totalSentBytes = 0
        pendingIncomingData.removeAll(keepingCapacity: false)
    }

    private func startReadLoop() {
        guard fileDescriptor >= 0 else { return }

        let descriptor = fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: ioQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(descriptor, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(buffer.prefix(bytesRead))
                Task { @MainActor in
                    self.totalReceivedBytes += data.count
                    self.enqueueIncoming(data)
                }
            } else if bytesRead < 0 {
                Task { @MainActor in
                    self.errorMessage = "Falha na leitura da porta serial."
                    self.closeConnection()
                }
            }
        }
        source.resume()
        readSource = source
    }

    private func configurePort(_ descriptor: Int32) throws {
        var options = termios()
        guard tcgetattr(descriptor, &options) == 0 else {
            throw SerialError.configuration("Não foi possível ler os atributos da porta.")
        }

        cfmakeraw(&options)

        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= bitMaskForDataBits(dataBits)

        if stopBits == 2 {
            options.c_cflag |= tcflag_t(CSTOPB)
        } else {
            options.c_cflag &= ~tcflag_t(CSTOPB)
        }

        switch parity {
        case .none:
            options.c_cflag &= ~tcflag_t(PARENB)
            options.c_iflag &= ~tcflag_t(INPCK)
        case .even:
            options.c_cflag |= tcflag_t(PARENB)
            options.c_cflag &= ~tcflag_t(PARODD)
            options.c_iflag |= tcflag_t(INPCK)
        case .odd:
            options.c_cflag |= tcflag_t(PARENB)
            options.c_cflag |= tcflag_t(PARODD)
            options.c_iflag |= tcflag_t(INPCK)
        }

        let speed = try speedFlag(for: selectedBaudRate)
        guard cfsetspeed(&options, speed) == 0 else {
            throw SerialError.configuration("Não foi possível ajustar o baudrate para \(selectedBaudRate).")
        }

        withUnsafeMutablePointer(to: &options.c_cc) { controlCharacters in
            controlCharacters.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { buffer in
                buffer[Int(VMIN)] = 1
                buffer[Int(VTIME)] = 0
            }
        }

        guard tcsetattr(descriptor, TCSANOW, &options) == 0 else {
            throw SerialError.configuration("Não foi possível aplicar a configuração da porta.")
        }

        guard fcntl(descriptor, F_SETFL, 0) == 0 else {
            throw SerialError.configuration("Não foi possível colocar a porta em modo bloqueante.")
        }
    }

    private func bitMaskForDataBits(_ dataBits: Int) -> tcflag_t {
        switch dataBits {
        case 5: return tcflag_t(CS5)
        case 6: return tcflag_t(CS6)
        case 7: return tcflag_t(CS7)
        default: return tcflag_t(CS8)
        }
    }

    private func speedFlag(for baudRate: Int) throws -> speed_t {
        switch baudRate {
        case 1200: return speed_t(B1200)
        case 2400: return speed_t(B2400)
        case 4800: return speed_t(B4800)
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default:
            throw SerialError.configuration("Baudrate \(baudRate) não suportado nesta versão.")
        }
    }

    private func appendEvent(_ message: String) {
        appendLogEntry(SerialLogEntry(direction: .event, message: message))
    }

    private func enqueueIncoming(_ data: Data) {
        pendingIncomingData.append(data)

        guard pendingFlushTask == nil else { return }

        pendingFlushTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            flushPendingIncoming()
        }
    }

    private func flushPendingIncoming() {
        pendingFlushTask = nil

        guard !pendingIncomingData.isEmpty else { return }

        let chunk = pendingIncomingData
        pendingIncomingData.removeAll(keepingCapacity: true)
        appendLogEntry(SerialLogEntry(direction: .incoming, bytes: chunk))
    }

    private func appendLogEntry(_ entry: SerialLogEntry) {
        logEntries.append(entry)

        if logEntries.count > Self.maxLogEntries {
            logEntries.removeFirst(logEntries.count - Self.maxLogEntries)
        }
    }

    private static func discoverSerialPorts() -> [SerialPortDescriptor] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else {
            return []
        }

        let dictionary = matching as NSMutableDictionary
        dictionary[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        let kernResult = IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iterator)
        guard kernResult == KERN_SUCCESS else {
            return []
        }

        defer { IOObjectRelease(iterator) }

        var ports: [SerialPortDescriptor] = []

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            let name = IORegistryEntryCreateCFProperty(service, kIOTTYDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String

            if let path {
                ports.append(SerialPortDescriptor(
                    path: path,
                    displayName: name.map { "\($0) (\(path))" } ?? path
                ))
            }
        }

        return ports.sorted { lhs, rhs in
            let lhsPriority = portPriority(for: lhs)
            let rhsPriority = portPriority(for: rhs)

            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func portPriority(for port: SerialPortDescriptor) -> Int {
        let normalizedName = port.displayName.lowercased()
        let normalizedPath = port.path.lowercased()

        if normalizedName.hasPrefix("usbserial") || normalizedName.contains(" usbserial") {
            return 0
        }

        if normalizedPath.contains("usbserial") {
            return 0
        }

        return 1
    }

    private static func decodeHexString(_ value: String) -> Data? {
        let sanitized = value
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)

        guard !sanitized.isEmpty else { return Data() }

        var bytes = Data()
        for pair in sanitized {
            guard let value = UInt8(pair, radix: 16) else {
                return nil
            }
            bytes.append(value)
        }
        return bytes
    }
}

enum SerialError: LocalizedError {
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message):
            return message
        }
    }
}
