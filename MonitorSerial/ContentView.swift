//
//  ContentView.swift
//  MonitorSerial
//
//  Created by Geovane Ferreira on 26/03/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var serialService = SerialPortService()

    @State private var selectedDisplayMode: PayloadDisplayMode = .hex
    @State private var selectedSendMode: PayloadDisplayMode = .ascii
    @State private var autoScroll = true
    @State private var logByLine = true
    @State private var showTimestamps = true
    @State private var showLineBoxes = true
    @State private var allowLogSelection = false
    @State private var composerText = ""
    @State private var savedCommands: [SavedCommand] = SavedCommand.samples
    @State private var newCommandTitle = ""
    @State private var newCommandPayload = ""
    @State private var isCommandsPanelVisible = false

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
            serialService.refreshPorts()
            loadSavedCommands()
        }
        .onChange(of: savedCommands) { _, _ in
            persistSavedCommands()
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
                                    Spacer()
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
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Button {
                                    sendSavedCommand(command)
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
                    Toggle("Linha a linha", isOn: $logByLine)
                        .toggleStyle(.switch)
                    Toggle("Timestamp", isOn: $showTimestamps)
                        .toggleStyle(.switch)
                    Toggle("Boxes", isOn: $showLineBoxes)
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
            ScrollView {
                if allowLogSelection {
                    Text(selectionLogText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(renderedEntries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                if showTimestamps {
                                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color(red: 0.33, green: 0.73, blue: 0.93))
                                        .frame(width: 90, alignment: .leading)
                                }

                                Text(entry.direction.symbol)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(entry.direction.color)
                                    .frame(width: 24)

                                Text(entry.payloadText(mode: selectedDisplayMode))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.disabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(rowBackground)
                            .id(entry.id)
                        }
                    }
                    .padding(14)
                }

                Color.clear
                    .frame(height: 1)
                    .id("log-bottom")
            }
            .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .onChange(of: serialService.totalReceivedBytes) { _, _ in
                scrollLogToBottom(with: proxy)
            }
            .onChange(of: serialService.totalSentBytes) { _, _ in
                scrollLogToBottom(with: proxy)
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if showLineBoxes {
            RoundedRectangle(cornerRadius: 16)
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

                Button {
                    sendComposer()
                } label: {
                    Label("Enviar", systemImage: "paperplane.fill")
                        .frame(width: 126)
                        .frame(minHeight: 72)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.12, green: 0.72, blue: 0.46))
                .disabled(!serialService.isConnected || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var settingsSidebar: some View {
        panelCard {
            VStack(alignment: .leading, spacing: 18) {
                panelHeader(
                    title: "Conexão",
                    subtitle: "Selecione a porta, configure a UART e conecte."
                )

                Group {
                    settingRow(label: "Porta") {
                        Picker("Porta", selection: $serialService.selectedPortPath) {
                            ForEach(serialService.availablePorts) { port in
                                Text(port.displayName).tag(port.path as String?)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    settingRow(label: "Baudrate") {
                        Picker("Baudrate", selection: $serialService.selectedBaudRate) {
                            ForEach(SerialPortService.supportedBaudRates, id: \.self) { baud in
                                Text("\(baud)").tag(baud)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    settingRow(label: "Data bits") {
                        Picker("Data bits", selection: $serialService.dataBits) {
                            ForEach([5, 6, 7, 8], id: \.self) { bits in
                                Text("\(bits)").tag(bits)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    settingRow(label: "Paridade") {
                        Picker("Paridade", selection: $serialService.parity) {
                            ForEach(SerialParity.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    settingRow(label: "Stop bits") {
                        Picker("Stop bits", selection: $serialService.stopBits) {
                            ForEach([1, 2], id: \.self) { bits in
                                Text("\(bits)").tag(bits)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    settingRow(label: "Buffer limit") {
                        Picker("Buffer limit", selection: $serialService.receiveBufferLimit) {
                            ForEach(SerialPortService.supportedBufferLimits, id: \.self) { limit in
                                Text("\(limit) bytes").tag(limit)
                            }
                        }
                        .pickerStyle(.menu)
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
                    Text("Sessão")
                        .font(.headline)

                    statusRow(title: "Porta ativa", value: serialService.activePortName ?? "Nenhuma")
                    statusRow(title: "Estado", value: serialService.isConnected ? "Conectado" : "Desconectado")
                    statusRow(title: "Visualização", value: selectedDisplayMode.label)
                    statusRow(title: "Envio", value: selectedSendMode.label)
                    statusRow(title: "Buffer RX", value: "\(serialService.receiveBufferLimit) bytes")
                    statusRow(title: "Linhas", value: "\(serialService.visibleLineLimit)")
                    statusRow(title: "Descartado", value: "\(serialService.droppedIncomingBytes) bytes")
                }

                Spacer(minLength: 0)
            }
        }
        .frame(width: 320)
    }

    private var renderedEntries: [SerialLogEntry] {
        guard logByLine else {
            let merged = serialService.mergedEntries
            let count = min(serialService.visibleLineLimit, merged.count)
            return Array(merged.suffix(count))
        }
        let entries = serialService.logEntries
        let count = min(serialService.visibleLineLimit, entries.count)
        return Array(entries.suffix(count))
    }

    private var selectionLogText: String {
        renderedEntries.map { entry in
            var components: [String] = []

            if showTimestamps {
                components.append(entry.timestamp.formatted(date: .omitted, time: .standard))
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
        serialService.send(payload, mode: selectedSendMode)
        composerText = ""
    }

    private func sendSavedCommand(_ command: SavedCommand) {
        serialService.send(command.payload, mode: command.mode)
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
        guard autoScroll else { return }
        proxy.scrollTo("log-bottom", anchor: .bottom)
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
}

#Preview {
    ContentView()
}
