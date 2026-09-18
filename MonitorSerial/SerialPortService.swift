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

private let macOSCustomBaudRateRequest: UInt = 0x80045402

struct SerialPortDescriptor: Identifiable, Hashable {
    var id: String { path }
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

enum CommandIntervalUnit: String, CaseIterable, Identifiable, Codable, Equatable {
    case milliseconds
    case seconds

    var id: String { rawValue }

    var label: String {
        switch self {
        case .milliseconds:
            return "ms"
        case .seconds:
            return "s"
        }
    }

    var nanosecondsMultiplier: UInt64 {
        switch self {
        case .milliseconds:
            return 1_000_000
        case .seconds:
            return 1_000_000_000
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
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    let id = UUID()
    let timestamp: Date
    let direction: SerialDirection
    let bytes: Data
    let message: String?
    let timestampLabel: String
    private let asciiPayload: String
    private let hexPayload: String

    init(timestamp: Date = .now, direction: SerialDirection, bytes: Data = Data(), message: String? = nil) {
        self.timestamp = timestamp
        self.direction = direction
        self.bytes = bytes
        self.message = message
        timestampLabel = Self.timestampFormatter.string(from: timestamp)

        if let message {
            asciiPayload = message
            hexPayload = message
        } else {
            let decoded = String(decoding: bytes, as: UTF8.self)
            asciiPayload = decoded.isEmpty ? "<vazio>" : decoded.replacingOccurrences(of: "\0", with: "·")
            hexPayload = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    func payloadText(mode: PayloadDisplayMode) -> String {
        switch mode {
        case .ascii:
            return asciiPayload
        case .hex:
            return hexPayload
        }
    }

    func canMerge(with other: SerialLogEntry) -> Bool {
        direction == other.direction && message == nil && other.message == nil
    }

    func prepending(_ older: SerialLogEntry) -> SerialLogEntry {
        SerialLogEntry(timestamp: older.timestamp, direction: direction, bytes: older.bytes + bytes)
    }
}

struct SavedCommand: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let payload: String
    let mode: PayloadDisplayMode
    let repeatCount: Int
    let intervalValue: Double
    let intervalUnit: CommandIntervalUnit

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case payload
        case mode
        case repeatCount
        case intervalValue
        case intervalUnit
    }

    init(
        id: UUID = UUID(),
        title: String,
        payload: String,
        mode: PayloadDisplayMode,
        repeatCount: Int = 1,
        intervalValue: Double = 0,
        intervalUnit: CommandIntervalUnit = .milliseconds
    ) {
        self.id = id
        self.title = title
        self.payload = payload
        self.mode = mode
        self.repeatCount = repeatCount
        self.intervalValue = intervalValue
        self.intervalUnit = intervalUnit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        payload = try container.decode(String.self, forKey: .payload)
        mode = try container.decode(PayloadDisplayMode.self, forKey: .mode)
        repeatCount = try container.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
        intervalValue = try container.decodeIfPresent(Double.self, forKey: .intervalValue) ?? 0
        intervalUnit = try container.decodeIfPresent(CommandIntervalUnit.self, forKey: .intervalUnit) ?? .milliseconds
    }

    static let samples: [SavedCommand] = [
        SavedCommand(title: "Ping módulo", payload: "AT", mode: .ascii),
        SavedCommand(title: "Ler status", payload: "7E 01 03 01 01 34 00 01", mode: .hex),
        SavedCommand(title: "Reset", payload: "7E 01 03 01 01 35 00 01", mode: .hex)
    ]
}

@MainActor
final class SerialPortService: ObservableObject {
    static let supportedBaudRates = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 921600]
    static let supportedBufferLimits = [150, 256, 512, 1024, 2048, 4096]
    static let absoluteMaxLogEntries = 1500
    static let supportedVisibleLineLimits = [10, 25, 50, 100, 150, 200, 300, 500, 750, 1000, 1500]

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
    @Published var droppedIncomingBytes = 0
    @Published var receiveBufferLimit = 1024
    @Published var visibleLineLimit = 300
    @Published private(set) var logUpdateID = 0
    @Published private(set) var isModemBridgeRunning = false
    @Published private(set) var isModemBridgeBusy = false
    @Published private(set) var modemBridgeStatus = "Parado"

    private var fileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var directoryWatchers: [DispatchSourceFileSystemObject] = []
    private var portRefreshTimer: Timer?
    private var isMonitoringPorts = false
    private let ioQueue = DispatchQueue(label: "monitorserial.serial.io", qos: .userInitiated)
    private var pendingIncomingData = Data()
    private var pendingFlushTask: Task<Void, Never>?

    init() {
        startMonitoringPorts()
    }

    var statusSummary: String {
        if isConnected {
            return "\(activePortName ?? "Porta serial") conectada em \(selectedBaudRate) bps"
        }
        return "Pronto para conectar e monitorar a UART"
    }

    var isModemScriptAvailable: Bool {
        FileManager.default.isReadableFile(atPath: Self.modemStartScriptURL.path)
    }

    func visibleEntries(limit: Int, mergeAdjacent: Bool) -> [SerialLogEntry] {
        guard limit > 0, !logEntries.isEmpty else { return [] }

        if !mergeAdjacent {
            return Array(logEntries.suffix(limit))
        }

        var mergedFromEnd: [SerialLogEntry] = []
        var pending: SerialLogEntry?

        for entry in logEntries.reversed() {
            if let current = pending, current.canMerge(with: entry) {
                pending = current.prepending(entry)
                continue
            }

            if let current = pending {
                mergedFromEnd.append(current)
                if mergedFromEnd.count == limit {
                    break
                }
            }

            pending = entry
        }

        if mergedFromEnd.count < limit, let pending {
            mergedFromEnd.append(pending)
        }

        return Array(mergedFromEnd.prefix(limit).reversed())
    }

    func startMonitoringPorts() {
        guard !isMonitoringPorts else {
            refreshPorts()
            return
        }

        isMonitoringPorts = true
        refreshPorts()
        startDirectoryWatchers()
        startPeriodicRefresh()
    }

    func refreshPorts() {
        var discovered = Self.discoverSerialPorts()
        let previousSelection = selectedPortPath

        if isConnected, let previousSelection, !discovered.contains(where: { $0.path == previousSelection }) {
            discovered.insert(
                SerialPortDescriptor(
                    path: previousSelection,
                    displayName: URL(fileURLWithPath: previousSelection).lastPathComponent
                ),
                at: 0
            )
        }

        if availablePorts != discovered {
            availablePorts = discovered
        }

        if isConnected, let previousSelection {
            selectedPortPath = previousSelection
            return
        }

        if previousSelection == nil || !discovered.contains(where: { $0.path == previousSelection }) {
            selectedPortPath = discovered.first?.path
        }

        refreshModemBridgeStatus()
    }

    func startModemBridge() {
        Task {
            await runModemBridgeScript(Self.modemStartScriptURL, action: .start)
        }
    }

    func stopModemBridge() {
        if isConnected, selectedPortPath?.localizedCaseInsensitiveContains("qcserial") == true {
            errorMessage = "Feche a conexão serial antes de parar o qcseriald."
            return
        }

        Task {
            await runModemBridgeScript(Self.modemStopScriptURL, action: .stop)
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

    func send(_ payload: String, mode: PayloadDisplayMode, appendCRLF: Bool = false) {
        guard fileDescriptor >= 0 else {
            errorMessage = "Abra a conexão antes de enviar comandos."
            return
        }

        let bytesToSend: Data
        switch mode {
        case .ascii:
            let finalPayload = appendCRLF ? payload + "\r\n" : payload
            bytesToSend = Data(finalPayload.utf8)
        case .hex:
            let finalPayload = appendCRLF ? payload + " 0D 0A" : payload
            guard let decoded = Self.decodeHexString(finalPayload) else {
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
        droppedIncomingBytes = 0
        pendingIncomingData.removeAll(keepingCapacity: false)
        logUpdateID &+= 1
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

        try applyCustomBaudRateIfNeeded(descriptor)

        guard tcflush(descriptor, TCIFLUSH) == 0 else {
            throw SerialError.configuration("Não foi possível limpar o buffer de entrada da porta.")
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
        case 921600: return speed_t(B38400)
        default:
            throw SerialError.configuration("Baudrate \(baudRate) não suportado nesta versão.")
        }
    }

    private func applyCustomBaudRateIfNeeded(_ descriptor: Int32) throws {
        guard selectedBaudRate == 921600 else { return }

        var speed = speed_t(selectedBaudRate)
        let result = withUnsafeMutablePointer(to: &speed) { pointer in
            ioctl(descriptor, macOSCustomBaudRateRequest, pointer)
        }

        guard result == 0 else {
            throw SerialError.configuration("Não foi possível aplicar o baudrate customizado de \(selectedBaudRate).")
        }
    }

    private func appendEvent(_ message: String) {
        appendLogEntry(SerialLogEntry(direction: .event, message: message))
    }

    private func enqueueIncoming(_ data: Data) {
        guard data.count <= receiveBufferLimit else {
            droppedIncomingBytes += data.count
            appendEvent("Pacote RX descartado: \(data.count) bytes acima do limite de \(receiveBufferLimit)")
            return
        }

        if pendingIncomingData.count + data.count > receiveBufferLimit {
            droppedIncomingBytes += pendingIncomingData.count + data.count
            pendingIncomingData.removeAll(keepingCapacity: true)
            pendingFlushTask?.cancel()
            pendingFlushTask = nil
            appendEvent("Buffer RX descartado: excedeu o limite de \(receiveBufferLimit) bytes")
            return
        }

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

        if logEntries.count > Self.absoluteMaxLogEntries {
            logEntries.removeFirst(logEntries.count - Self.absoluteMaxLogEntries)
        }

        logUpdateID &+= 1
    }

    private enum ModemBridgeAction {
        case start
        case stop

        var busyLabel: String {
            switch self {
            case .start:
                return "Iniciando..."
            case .stop:
                return "Parando..."
            }
        }

        var eventVerb: String {
            switch self {
            case .start:
                return "iniciar"
            case .stop:
                return "parar"
            }
        }
    }

    private func runModemBridgeScript(_ scriptURL: URL, action: ModemBridgeAction) async {
        guard !isModemBridgeBusy else { return }

        guard FileManager.default.isReadableFile(atPath: scriptURL.path) else {
            errorMessage = "Script do qcseriald não encontrado em \(scriptURL.path)."
            return
        }

        isModemBridgeBusy = true
        modemBridgeStatus = action.busyLabel
        appendEvent("Executando \(scriptURL.lastPathComponent) para \(action.eventVerb) as portas SIMCOM/Quectel...")

        do {
            let output = try await Self.runScriptWithAdministratorPrivileges(scriptURL)
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOutput.isEmpty {
                appendEvent("\(scriptURL.lastPathComponent) concluído.")
            } else {
                appendEvent(trimmedOutput)
            }
        } catch {
            errorMessage = error.localizedDescription
            appendEvent("Falha ao \(action.eventVerb) o qcseriald.")
        }

        isModemBridgeBusy = false
        refreshPorts()
    }

    private func refreshModemBridgeStatus() {
        let running = Self.isQcserialdProcessRunning() || Self.hasQcserialPorts()

        if isModemBridgeRunning != running {
            isModemBridgeRunning = running
        }

        guard !isModemBridgeBusy else { return }
        modemBridgeStatus = running ? "Ativo" : "Parado"
    }

    private static func isQcserialdProcessRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-qx", "qcseriald"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func hasQcserialPorts() -> Bool {
        discoverFilesystemSerialPorts().contains { port in
            port.path.localizedCaseInsensitiveContains("qcserial")
        }
    }

    private static var modemScriptDirectory: URL {
        let candidates = [
            URL(fileURLWithPath: "/Users/geovaneferreira/Repositorios/GitHub_Geovane/qcseriald-darwin", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Repositorios/GitHub_Geovane/qcseriald-darwin", isDirectory: true)
        ]

        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("iniciar.sh").path) }
            ?? candidates[0]
    }

    private static var modemStartScriptURL: URL {
        modemScriptDirectory.appendingPathComponent("iniciar.sh")
    }

    private static var modemStopScriptURL: URL {
        modemScriptDirectory.appendingPathComponent("parar.sh")
    }

    private static func runScriptWithAdministratorPrivileges(_ scriptURL: URL) async throws -> String {
        let quotedPath = "'" + scriptURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let appleScript = """
        do shell script "bash \(quotedPath)" with administrator privileges with prompt "Monitor Serial precisa de administrador para criar as portas SIMCOM/Quectel no Mac."
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if finishedProcess.terminationStatus == 0 {
                    continuation.resume(returning: output)
                    return
                }

                let lowered = errorOutput.lowercased()
                let message: String
                if lowered.contains("canceled") || lowered.contains("cancelled") {
                    message = "Autorização cancelada. As portas do modem não foram alteradas."
                } else if errorOutput.isEmpty {
                    message = "Falha ao executar \(scriptURL.lastPathComponent)."
                } else {
                    message = errorOutput
                }

                continuation.resume(throwing: SerialError.configuration(message))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func startDirectoryWatchers() {
        directoryWatchers.forEach { $0.cancel() }
        directoryWatchers.removeAll()

        for directory in Self.watchedPortDirectories {
            let descriptor = open(directory, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.refreshPorts()
                }
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            directoryWatchers.append(source)
        }
    }

    private func startPeriodicRefresh() {
        portRefreshTimer?.invalidate()
        portRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPorts()
            }
        }
    }

    private static var homeDevDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev", isDirectory: true).path
    }

    private static var watchedPortDirectories: [String] {
        [homeDevDirectory, "/dev"]
    }

    private static func discoverSerialPorts() -> [SerialPortDescriptor] {
        var portsByPath: [String: SerialPortDescriptor] = [:]

        for port in discoverIOKitSerialPorts() {
            portsByPath[port.path] = port
        }

        for port in discoverFilesystemSerialPorts() {
            if portsByPath[port.path] == nil {
                portsByPath[port.path] = port
            }
        }

        return preferCalloutDevices(Array(portsByPath.values)).sorted { lhs, rhs in
            let lhsPriority = portPriority(for: lhs)
            let rhsPriority = portPriority(for: rhs)

            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func discoverIOKitSerialPorts() -> [SerialPortDescriptor] {
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

        return ports
    }

    private static func discoverFilesystemSerialPorts() -> [SerialPortDescriptor] {
        ports(in: homeDevDirectory, requireSerialName: false)
            + ports(in: "/dev", requireSerialName: true)
    }

    private static func ports(in directory: String, requireSerialName: Bool) -> [SerialPortDescriptor] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return []
        }

        return entries.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            if requireSerialName && !isSerialDeviceName(name) {
                return nil
            }

            let path = (directory as NSString).appendingPathComponent(name)
            guard isUsableSerialPath(path) else {
                return nil
            }

            return SerialPortDescriptor(path: path, displayName: displayName(forPath: path))
        }
    }

    private static func displayName(forPath path: String) -> String {
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        if path.hasPrefix(homeDevDirectory) {
            return "\(fileName) (~/dev)"
        }
        return "\(fileName) (\(path))"
    }

    private static func isUsableSerialPath(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }

        let type = info.st_mode & S_IFMT
        if type == S_IFCHR {
            return true
        }

        guard type == S_IFLNK else { return false }

        var target = stat()
        return stat(path, &target) == 0 && (target.st_mode & S_IFMT) == S_IFCHR
    }

    private static func isSerialDeviceName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.hasPrefix("cu.")
            || normalized.hasPrefix("tty.")
            || normalized.hasPrefix("ttyusb")
            || normalized.hasPrefix("ttyacm")
            || normalized.contains("qcserial")
            || normalized.contains("usbserial")
            || normalized.contains("usbmodem")
    }

    private static func preferCalloutDevices(_ ports: [SerialPortDescriptor]) -> [SerialPortDescriptor] {
        let paths = Set(ports.map(\.path))
        return ports.filter { port in
            let url = URL(fileURLWithPath: port.path)
            let name = url.lastPathComponent
            guard name.hasPrefix("tty.") else { return true }

            let calloutPath = url
                .deletingLastPathComponent()
                .appendingPathComponent("cu." + name.dropFirst(4))
                .path
            return !paths.contains(calloutPath)
        }
    }

    private static func portPriority(for port: SerialPortDescriptor) -> Int {
        let normalized = "\(port.displayName) \(port.path)".lowercased()

        if normalized.contains("qcserial") && normalized.contains("at") {
            return 0
        }

        if normalized.contains("qcserial") {
            return 1
        }

        if normalized.contains("usbserial") {
            return 2
        }

        if normalized.contains("usbmodem") {
            return 3
        }

        if normalized.contains("/dev") && !port.path.hasPrefix("/dev/") {
            return 4
        }

        return 5
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
