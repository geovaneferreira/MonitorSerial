//
//  ContentView.swift
//  MonitorSerial
//
//  Created by Geovane Ferreira on 26/03/26.
//

import SwiftUI

private struct LogContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct LogViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ContentView: View {
    @StateObject private var serialService = SerialPortService()

    enum LogInsertMode: String, CaseIterable, Identifiable {
        case bottom
        case top

        var id: String { rawValue }

        var label: String {
            switch self {
            case .bottom:
                return "Novos embaixo"
            case .top:
                return "Novos no topo"
            }
        }
    }

    @State private var selectedDisplayMode: PayloadDisplayMode = .hex
    @State private var selectedSendMode: PayloadDisplayMode = .ascii
    @State private var autoScroll = true
    @State private var logByLine = true
    @State private var showTimestamps = true
    @State private var showLineBoxes = true
    @State private var wrapLogLines = true
    @State private var allowLogSelection = false
    @State private var appendCRLFOnManualSend = false
    @State private var logInsertMode: LogInsertMode = .bottom
    @State private var composerText = ""
    @State private var savedCommands: [SavedCommand] = SavedCommand.samples
    @State private var newCommandTitle = ""
    @State private var newCommandPayload = ""
    @State private var isCommandsPanelVisible = false
    @State private var expandedCommandIDs: Set<UUID> = []
    @State private var logContentHeight: CGFloat = 0
    @State private var logViewportHeight: CGFloat = 0

    var body: some View {
        HStack(spacing: 18) {
            settingsSidebar
            consolePanel
            if isCommandsPanelVisible {
                savedCommandsPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(20)
        .frame(minWidth: 1380, minHeight: 860)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.08, blue: 0.11),
                    Color(red: 0.04, green: 0.05, blue: 0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isCommandsPanelVisible)
        .onAppear {
            serialService.startMonitoringPorts()
            loadSavedCommands()
        }
        .onChange(of: savedCommands) { _, _ in
            persistSavedCommands()
        }
        .onChange(of: logInsertMode) { _, newValue in
            if newValue == .top {
                autoScroll = false
            }
        }
        .alert("Erro na conexão serial", isPresented: Binding(
            get: { serialService.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    serialService.errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                serialService.errorMessage = nil
            }
        } message: {
            Text(serialService.errorMessage ?? "")
        }
    }

    private var savedCommandsPanel: some View {
        panelCard {
            VStack(alignment: .leading, spacing: 18) {
                panelHeader(
                    title: "Comandos rápidos",
                    subtitle: "Monte uma biblioteca lateral e dispare com um clique."
                )

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(savedCommands) { command in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(command.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    Button {
                                        toggleCommandExpansion(command)
                                    } label: {
                                        Image(systemName: expandedCommandIDs.contains(command.id) ? "slider.horizontal.3" : "slider.horizontal.3")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Color.white.opacity(0.8))
                                            .padding(8)
                                            .background(Color.white.opacity(0.08), in: Circle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        removeSavedCommand(command)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Color.red.opacity(0.85))
                                            .padding(8)
                                            .background(Color.red.opacity(0.12), in: Circle())
                                    }
                                    .buttonStyle(.plain)

                                    Text(command.mode.label)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.08), in: Capsule())
                                }

                                Text(command.payload)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                HStack(spacing: 8) {
                                    compactInfoPill(title: "Rep", value: "\(command.repeatCount)x")
                                    compactInfoPill(
                                        title: "Int",
                                        value: command.repeatCount > 1 ? "\(formattedInterval(command.intervalValue)) \(command.intervalUnit.label)" : "-"
                                    )
                                    Spacer()
                                }

                                if expandedCommandIDs.contains(command.id) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Repetições")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.secondary)
                                            Stepper(value: repeatCountBinding(for: command), in: 1...999) {
                                                Text("\(command.repeatCount)x")
                                                    .font(.caption.weight(.semibold))
                                            }
                                        }

                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Intervalo")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.secondary)
                                            HStack(spacing: 8) {
                                                TextField("0", value: intervalValueBinding(for: command), format: .number)
                                                    .textFieldStyle(.plain)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 8)
                                                    .frame(width: 72)
                                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

                                                Picker("", selection: intervalUnitBinding(for: command)) {
                                                    ForEach(CommandIntervalUnit.allCases) { unit in
                                                        Text(unit.label == "ms" ? "milissegundos" : "segundos").tag(unit)
                                                    }
                                                }
                                                .labelsHidden()
                                                .pickerStyle(.menu)
                                                .frame(maxWidth: .infinity)
                                            }
                                        }
                                    }
                                    .padding(12)
                                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                                }

                                Button {
                                    Task {
                                        await sendSavedCommand(command)
                                    }
                                } label: {
                                    Label("Enviar", systemImage: "paperplane.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color(red: 0.15, green: 0.55, blue: 0.98))
                                .disabled(!serialService.isConnected)
                            }
                            .padding(14)
                            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                            )
                        }
                    }
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Novo comando")
                        .font(.subheadline.weight(.semibold))

                    TextField("Nome do comando", text: $newCommandTitle)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                    TextField("Payload ASCII ou HEX", text: $newCommandPayload)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                    Button {
                        addSavedCommand()
                    } label: {
                        Label("Adicionar à lateral", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(newCommandTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newCommandPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 300)
    }

    private var consolePanel: some View {
        panelCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Monitor Serial")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text(serialService.statusSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        Button {
                            isCommandsPanelVisible.toggle()
                        } label: {
                            Label(isCommandsPanelVisible ? "Ocultar comandos" : "Mostrar comandos", systemImage: "sidebar.right")
                        }
                        .buttonStyle(.bordered)

                        statBadge(title: "RX", value: "\(serialService.totalReceivedBytes) bytes")
                        statBadge(title: "TX", value: "\(serialService.totalSentBytes) bytes")
                    }
                }

                HStack(spacing: 12) {
                    segmentedButton(title: "ASCII", isSelected: selectedDisplayMode == .ascii) {
                        selectedDisplayMode = .ascii
                    }
                    segmentedButton(title: "HEX", isSelected: selectedDisplayMode == .hex) {
                        selectedDisplayMode = .hex
                    }

                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.switch)
                        .disabled(logInsertMode == .top)
                    Toggle("Linha a linha", isOn: $logByLine)
                        .toggleStyle(.switch)
                    Toggle("Timestamp", isOn: $showTimestamps)
                        .toggleStyle(.switch)
                    Toggle("Boxes", isOn: $showLineBoxes)
                        .toggleStyle(.switch)
                    Toggle("Quebra linha", isOn: $wrapLogLines)
                        .toggleStyle(.switch)
                    Toggle("Seleção", isOn: $allowLogSelection)
                        .toggleStyle(.switch)

                    Spacer()

                    Button(role: .destructive) {
                        serialService.clearLog()
                    } label: {
                        Label("Limpar", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }

                logPanel

                composerPanel
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var logPanel: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(logScrollAxes) {
                    VStack(alignment: .leading, spacing: 0) {
                        if allowLogSelection {
                            Text(selectionLogText)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .lineLimit(wrapLogLines ? nil : 1)
                                .fixedSize(horizontal: !wrapLogLines, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        } else {
                            LazyVStack(alignment: .leading, spacing: showLineBoxes ? 2 : 1) {
                                ForEach(renderedEntries) { entry in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        if showTimestamps {
                                            Text(entry.timestampLabel)
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(Color(red: 0.33, green: 0.73, blue: 0.93))
                                                .frame(width: 108, alignment: .leading)
                                        }

                                        Text(entry.direction.symbol)
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .foregroundStyle(entry.direction.color)
                                            .frame(width: 18)

                                        Text(entry.payloadText(mode: selectedDisplayMode))
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .textSelection(.disabled)
                                            .lineLimit(wrapLogLines ? nil : 1)
                                            .fixedSize(horizontal: !wrapLogLines, vertical: wrapLogLines)
                                            .frame(maxWidth: wrapLogLines ? .infinity : nil, alignment: .leading)
                                    }
                                    .padding(.horizontal, showLineBoxes ? 8 : 0)
                                    .padding(.vertical, showLineBoxes ? 4 : 1)
                                    .background(rowBackground)
                                    .id(entry.id)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }

                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 8)
                            .id("log-bottom")
                    }
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                    .background(
                        GeometryReader { contentGeometry in
                            Color.clear
                                .preference(key: LogContentHeightKey.self, value: contentGeometry.size.height)
                        }
                    )
                }
                .id(wrapLogLines)
                .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 24))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .background(
                    GeometryReader { viewportGeometry in
                        Color.clear
                            .preference(key: LogViewportHeightKey.self, value: viewportGeometry.size.height)
                    }
                )
                .onPreferenceChange(LogContentHeightKey.self) { logContentHeight = $0 }
                .onPreferenceChange(LogViewportHeightKey.self) { logViewportHeight = $0 }
                .onChange(of: serialService.logUpdateID) { _, _ in
                    scrollLogToBottom(with: proxy)
                }
                .onChange(of: logContentHeight) { _, _ in
                    scrollLogToBottom(with: proxy)
                }
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if showLineBoxes {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
        } else {
            Rectangle()
                .fill(Color.clear)
        }
    }

    private var composerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Envio manual")
                    .font(.headline)
                Spacer()
                segmentedButton(title: "ASCII", isSelected: selectedSendMode == .ascii) {
                    selectedSendMode = .ascii
                }
                segmentedButton(title: "HEX", isSelected: selectedSendMode == .hex) {
                    selectedSendMode = .hex
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField("Digite um comando ou uma sequência HEX...", text: $composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .padding(14)
                    .frame(minHeight: 72)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

                VStack(spacing: 10) {
                    Toggle("CR/LF", isOn: $appendCRLFOnManualSend)
                        .toggleStyle(.switch)

                    Button {
                        sendComposer()
                    } label: {
                        Label("Enviar", systemImage: "paperplane.fill")
                            .frame(width: 126)
                            .frame(minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.12, green: 0.72, blue: 0.46))
                    .disabled(!serialService.isConnected || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var settingsSidebar: some View {
        panelCard {
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                panelHeader(
                    title: "Conexão",
                    subtitle: "Selecione a porta, configure a UART e conecte."
                )

                Group {
                    settingRow(label: "Porta") {
                        Picker("Porta", selection: $serialService.selectedPortPath) {
                            if serialService.availablePorts.isEmpty {
                                Text("Nenhuma porta encontrada").tag(nil as String?)
                            }

                            ForEach(serialService.availablePorts) { port in
                                Text(port.displayName).tag(port.path as String?)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(serialService.isConnected)
                    }

                    settingRow(label: "Baudrate") {
                        Picker("Baudrate", selection: $serialService.selectedBaudRate) {
                            ForEach(SerialPortService.supportedBaudRates, id: \.self) { baud in
                                Text("\(baud)").tag(baud)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(serialService.isConnected)
                    }

                    settingRow(label: "Data bits") {
                        Picker("Data bits", selection: $serialService.dataBits) {
                            ForEach([5, 6, 7, 8], id: \.self) { bits in
                                Text("\(bits)").tag(bits)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(serialService.isConnected)
                    }

                    settingRow(label: "Paridade") {
                        Picker("Paridade", selection: $serialService.parity) {
                            ForEach(SerialParity.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(serialService.isConnected)
                    }

                    settingRow(label: "Stop bits") {
                        Picker("Stop bits", selection: $serialService.stopBits) {
                            ForEach([1, 2], id: \.self) { bits in
                                Text("\(bits)").tag(bits)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(serialService.isConnected)
                    }

                    settingRow(label: "Buffer limit") {
                        Picker("Buffer limit", selection: $serialService.receiveBufferLimit) {
                            ForEach(SerialPortService.supportedBufferLimits, id: \.self) { limit in
                                Text("\(limit) bytes").tag(limit)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(serialService.isConnected)
                    }

                    settingRow(label: "Linhas visíveis") {
                        Picker("Linhas visíveis", selection: $serialService.visibleLineLimit) {
                            ForEach(SerialPortService.supportedVisibleLineLimits, id: \.self) { limit in
                                let title = limit == SerialPortService.absoluteMaxLogEntries ? "MAX (\(limit))" : "\(limit)"
                                Text(title).tag(limit)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    settingRow(label: "Ordem") {
                        Picker("", selection: $logInsertMode) {
                            ForEach(LogInsertMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        serialService.refreshPorts()
                    } label: {
                        Label("Atualizar", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        toggleConnection()
                    } label: {
                        Label(serialService.isConnected ? "Fechar" : "Abrir", systemImage: serialService.isConnected ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(serialService.isConnected ? Color.red.opacity(0.8) : Color(red: 0.13, green: 0.57, blue: 0.95))
                    .disabled(serialService.selectedPortPath == nil)
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Portas modem")
                        .font(.headline)
                    Text("Inicia o qcseriald para criar as portas SIMCOM, Quectel e outros no Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            serialService.startModemBridge()
                        } label: {
                            Label("Iniciar", systemImage: "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.45, green: 0.38, blue: 0.92))
                        .disabled(serialService.isModemBridgeBusy || !serialService.isModemScriptAvailable)

                        Button {
                            serialService.stopModemBridge()
                        } label: {
                            Label("Parar", systemImage: "stop.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(serialService.isModemBridgeBusy || !serialService.isModemScriptAvailable)
                    }

                    coloredStatusRow(
                        title: "qcseriald",
                        value: serialService.modemBridgeStatus,
                        color: serialService.isModemBridgeRunning ? Color.green : Color.secondary
                    )
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Sessão")
                        .font(.headline)

                    statusRow(title: "Porta ativa", value: serialService.activePortName ?? "Nenhuma")
                    coloredStatusRow(
                        title: "Estado",
                        value: serialService.isConnected ? "Conectado" : "Desconectado",
                        color: serialService.isConnected ? Color.green : Color.red
                    )
                    statusRow(title: "Visualização", value: selectedDisplayMode.label)
                    statusRow(title: "Envio", value: selectedSendMode.label)
                    statusRow(title: "Buffer RX", value: "\(serialService.receiveBufferLimit) bytes")
                    statusRow(title: "Linhas", value: "\(serialService.visibleLineLimit)")
                    statusRow(title: "Descartado", value: "\(serialService.droppedIncomingBytes) bytes")
                }

            }
            }
        }
        .frame(width: 320)
    }

    private var renderedEntries: [SerialLogEntry] {
        let visibleEntries: [SerialLogEntry]

        guard logByLine else {
            visibleEntries = serialService.visibleEntries(limit: serialService.visibleLineLimit, mergeAdjacent: true)
            return orderedEntries(visibleEntries)
        }
        visibleEntries = serialService.visibleEntries(limit: serialService.visibleLineLimit, mergeAdjacent: false)
        return orderedEntries(visibleEntries)
    }

    private var logScrollAxes: Axis.Set {
        wrapLogLines ? .vertical : [.vertical, .horizontal]
    }

    private var selectionLogText: String {
        renderedEntries.map { entry in
            var components: [String] = []

            if showTimestamps {
                components.append(entry.timestampLabel)
            }

            components.append(entry.direction.symbol)
            components.append(entry.payloadText(mode: selectedDisplayMode))

            return components.joined(separator: "  ")
        }
        .joined(separator: "\n")
    }

    private func sendComposer() {
        let payload = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }
        serialService.send(payload, mode: selectedSendMode, appendCRLF: appendCRLFOnManualSend)
        composerText = ""
    }

    private func sendSavedCommand(_ command: SavedCommand) async {
        for index in 0..<command.repeatCount {
            serialService.send(command.payload, mode: command.mode)

            guard index < command.repeatCount - 1 else { continue }

            let interval = clampedIntervalValue(command.intervalValue)
            guard interval > 0 else { continue }
            let sleepNs = UInt64(interval * Double(command.intervalUnit.nanosecondsMultiplier))
            try? await Task.sleep(nanoseconds: sleepNs)
        }
    }

    private func addSavedCommand() {
        let title = newCommandTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = newCommandPayload.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty, !payload.isEmpty else { return }

        let inferredMode: PayloadDisplayMode = payload.contains(" ") ? .hex : .ascii
        savedCommands.append(SavedCommand(title: title, payload: payload, mode: inferredMode))
        newCommandTitle = ""
        newCommandPayload = ""
    }

    private func removeSavedCommand(_ command: SavedCommand) {
        savedCommands.removeAll { $0.id == command.id }
        expandedCommandIDs.remove(command.id)
    }

    private func toggleCommandExpansion(_ command: SavedCommand) {
        if expandedCommandIDs.contains(command.id) {
            expandedCommandIDs.remove(command.id)
        } else {
            expandedCommandIDs.insert(command.id)
        }
    }

    private func repeatCountBinding(for command: SavedCommand) -> Binding<Int> {
        Binding(
            get: { savedCommands.first(where: { $0.id == command.id })?.repeatCount ?? 1 },
            set: { newValue in
                updateSavedCommand(command.id) { current in
                    SavedCommand(
                        id: current.id,
                        title: current.title,
                        payload: current.payload,
                        mode: current.mode,
                        repeatCount: max(1, newValue),
                        intervalValue: current.intervalValue,
                        intervalUnit: current.intervalUnit
                    )
                }
            }
        )
    }

    private func intervalValueBinding(for command: SavedCommand) -> Binding<Double> {
        Binding(
            get: { savedCommands.first(where: { $0.id == command.id })?.intervalValue ?? 0 },
            set: { newValue in
                updateSavedCommand(command.id) { current in
                    SavedCommand(
                        id: current.id,
                        title: current.title,
                        payload: current.payload,
                        mode: current.mode,
                        repeatCount: current.repeatCount,
                        intervalValue: clampedIntervalValue(newValue),
                        intervalUnit: current.intervalUnit
                    )
                }
            }
        )
    }

    private func intervalUnitBinding(for command: SavedCommand) -> Binding<CommandIntervalUnit> {
        Binding(
            get: { savedCommands.first(where: { $0.id == command.id })?.intervalUnit ?? .milliseconds },
            set: { newValue in
                updateSavedCommand(command.id) { current in
                    SavedCommand(
                        id: current.id,
                        title: current.title,
                        payload: current.payload,
                        mode: current.mode,
                        repeatCount: current.repeatCount,
                        intervalValue: current.intervalValue,
                        intervalUnit: newValue
                    )
                }
            }
        )
    }

    private func updateSavedCommand(_ id: UUID, transform: (SavedCommand) -> SavedCommand) {
        guard let index = savedCommands.firstIndex(where: { $0.id == id }) else { return }
        savedCommands[index] = transform(savedCommands[index])
    }

    private func loadSavedCommands() {
        guard let data = try? Data(contentsOf: commandsFileURL),
              let commands = try? JSONDecoder().decode([SavedCommand].self, from: data) else {
            return
        }

        savedCommands = commands
    }

    private func persistSavedCommands() {
        do {
            let directory = commandsFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let data = try JSONEncoder().encode(savedCommands)
            try data.write(to: commandsFileURL, options: .atomic)
        } catch {
            serialService.errorMessage = "Não foi possível salvar os comandos rápidos."
        }
    }

    private var commandsFileURL: URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return baseDirectory
            .appendingPathComponent("MonitorSerial", isDirectory: true)
            .appendingPathComponent("saved-commands.json")
    }

    private func toggleConnection() {
        if serialService.isConnected {
            serialService.closeConnection()
        } else {
            serialService.openConnection()
        }
    }

    private func scrollLogToBottom(with proxy: ScrollViewProxy) {
        guard autoScroll, logInsertMode == .bottom else { return }
        DispatchQueue.main.async {
            let anchor = UnitPoint(x: 0, y: logContentHeight > logViewportHeight ? 1 : 0)
            proxy.scrollTo("log-bottom", anchor: anchor)
        }
    }

    private func orderedEntries(_ entries: [SerialLogEntry]) -> [SerialLogEntry] {
        if logInsertMode == .top {
            return Array(entries.reversed())
        }
        return entries
    }

    private func clampedIntervalValue(_ value: Double) -> Double {
        max(0, value)
    }

    private func formattedInterval(_ value: Double) -> String {
        if value == floor(value) {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private func panelCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func panelHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 21, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func statBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func compactInfoPill(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func segmentedButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Color(red: 0.18, green: 0.54, blue: 0.95) : Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }

    private func settingRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func statusRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    private func coloredStatusRow(title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.bold)
                .foregroundStyle(color)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
