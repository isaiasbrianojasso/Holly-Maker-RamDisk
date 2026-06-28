//
//  ContentView.swift
//  Holly Maker RamDisk
//
//  Created by Jose Isaias Briano Jasso on 28/06/26.
//

import SwiftUI
import Foundation
import AppKit

private enum L10n {
    static func text(_ key: String, _ defaultValue: String) -> String {
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
    }
}

struct ContentView: View {
    @AppStorage("selectedDeviceID") private var selectedDeviceID = SupportedDevice.compatible.first?.id ?? "iPhone12,1"
    @AppStorage("workFolder") private var workFolder = ""
    @AppStorage("keySource") private var keySource = ""
    @AppStorage("bootArguments") private var bootArguments = "rd=md0 -v"
    @AppStorage("toolsFolder") private var toolsFolder = "/usr/local/bin"
    @AppStorage("ramdiskSizeMB") private var ramdiskSizeMB = 128
    @AppStorage("includeSSH") private var includeSSH = true
    @AppStorage("preferSignedFirmwares") private var preferSignedFirmwares = true

    @State private var firmwareOptions: [IPSWFirmware] = []
    @State private var selectedFirmwareID = ""
    @State private var firmwareStatus = "Selecciona un modelo para cargar firmwares desde IPSW.me."
    @State private var firmwareSource = ""
    @State private var workflowState = WorkflowState.idle
    @State private var currentStage: WorkflowStage?
    @State private var completedStages: Set<WorkflowStage> = []
    @State private var logs: [LogEntry] = []
    @State private var artifactBundle = ArtifactBundle.empty
    @State private var workflowTask: Task<Void, Never>?

    private let ramdiskSizes = [96, 128, 192, 256, 512]

    private var selectedDevice: SupportedDevice {
        SupportedDevice.compatible.first { $0.id == selectedDeviceID } ?? SupportedDevice.compatible[0]
    }

    private var selectedFirmware: IPSWFirmware? {
        firmwareOptions.first { $0.id == selectedFirmwareID }
    }

    private var visibleFirmwares: [IPSWFirmware] {
        let signed = firmwareOptions.filter(\.signed)
        return preferSignedFirmwares && !signed.isEmpty ? signed : firmwareOptions
    }

    private var progress: Double {
        guard !WorkflowStage.allCases.isEmpty else { return 0 }
        return Double(completedStages.count) / Double(WorkflowStage.allCases.count)
    }

    private var canPrepare: Bool {
        !isRunning && requiredFields.allSatisfy { !$0.value.trimmed.isEmpty }
    }

    private var isRunning: Bool {
        if case .running = workflowState { return true }
        return false
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    contentLayout(for: proxy.size.width)
                }
                .padding(.horizontal, proxy.size.width < 720 ? 18 : 28)
                .padding(.vertical, 28)
                .frame(maxWidth: 1220)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .onChange(of: selectedDeviceID) { _ in
            clearFirmwareSelection()
        }
        .onChange(of: selectedFirmwareID) { _ in
            applySelectedFirmwareURL()
        }
        .onDisappear(perform: cancelPreparation)
    }

    @ViewBuilder
    private func contentLayout(for width: CGFloat) -> some View {
        let dashboard = ArtifactDashboard(
            state: workflowState,
            currentStage: currentStage,
            completedStages: completedStages,
            progress: progress,
            logs: logs,
            artifactBundle: artifactBundle
        )

        if width >= 1120 {
            HStack(alignment: .top, spacing: 24) {
                configurationPanel
                    .frame(width: 500, alignment: .topLeading)
                dashboard
                    .frame(minWidth: 520, maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                configurationPanel
                    .frame(maxWidth: 680, alignment: .topLeading)
                dashboard
                    .frame(maxWidth: 860, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("header.title", "Ramdisk preparer"))
                .font(.system(size: 34, weight: .bold))

            Text(L10n.text("header.subtitle", "Download or validate the IPSW and prepare a device-specific output folder with the filenames expected by other tools."))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 860, alignment: .leading)
    }

    private var configurationPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            PanelTitle(title: L10n.text("panel.configuration", "Configuration"), systemImage: "slider.horizontal.3")
            firmwarePickerSection
            Divider()
            artifactOptionsSection
            Text(L10n.text("configuration.notice", "This app does not send anything to the device. It only prepares local artifacts for use with other tools."))
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actionButtons
        }
        .panelStyle()
    }

    private var firmwarePickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("field.model", "Model"))
                    .font(.subheadline.weight(.semibold))

                Picker("Modelo", selection: $selectedDeviceID) {
                    ForEach(SupportedDevice.compatible) { device in
                        Text(device.displayName)
                            .lineLimit(1)
                            .tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(isRunning)
            }

            Toggle(L10n.text("toggle.preferSigned", "Prefer signed firmwares"), isOn: $preferSignedFirmwares)
                .toggleStyle(.switch)
                .disabled(isRunning)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.text("field.ipswFirmware", "IPSW firmware"))
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Button(action: refreshFirmwares) {
                        Label(L10n.text("button.reload", "Reload"), systemImage: "arrow.clockwise")
                    }
                    .disabled(isRunning)
                }

                Picker("Firmware IPSW", selection: $selectedFirmwareID) {
                    if visibleFirmwares.isEmpty {
                        Text(L10n.text("picker.noFirmwares", "No firmwares loaded")).tag("")
                    } else {
                        ForEach(visibleFirmwares) { firmware in
                            Text(firmware.displayName)
                                .lineLimit(1)
                                .tag(firmware.id)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(visibleFirmwares.isEmpty || isRunning)
            }

            if let selectedFirmware {
                FirmwareSummary(firmware: selectedFirmware)
            }

            Text(firmwareStatus)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FieldRow(title: L10n.text("field.ipswSource", "IPSW URL or path"), placeholder: L10n.text("placeholder.ipswSource", "Filled when selecting firmware"), text: $firmwareSource, isDisabled: isRunning)
        }
    }

    private var artifactOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            FieldRow(title: L10n.text("field.workFolder", "Work folder"), placeholder: "/Users/.../HollyBuild", text: $workFolder, isDisabled: isRunning)
            SecureFieldRow(title: L10n.text("field.keys", "Keys / manifest"), placeholder: L10n.text("placeholder.keys", "User file or text"), text: $keySource, isDisabled: isRunning)
            FieldRow(title: L10n.text("field.bootArgs", "Boot args"), placeholder: "rd=md0 -v", text: $bootArguments, isDisabled: isRunning)
            FieldRow(title: L10n.text("field.tools", "Tools"), placeholder: "/usr/local/bin", text: $toolsFolder, isDisabled: isRunning)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("field.ramdiskSize", "Ramdisk size"))
                    .font(.subheadline.weight(.semibold))

                Picker("Tamaño del ramdisk", selection: $ramdiskSizeMB) {
                    ForEach(ramdiskSizes, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                .disabled(isRunning)
            }

            Toggle(L10n.text("toggle.prepareSSH", "Prepare SSH folder"), isOn: $includeSSH)
                .toggleStyle(.switch)
                .disabled(isRunning)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button(action: startPreparation) {
                Label(L10n.text("button.prepareArtifacts", "Prepare artifacts"), systemImage: "shippingbox.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(canPrepare ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
            .disabled(!canPrepare)

            HStack(spacing: 10) {
                Button(action: cancelPreparation) {
                    Label(L10n.text("button.cancel", "Cancel"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!isRunning)

                Button(action: resetPreparation) {
                    Label(L10n.text("button.clear", "Clear"), systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isRunning)
            }
        }
    }

    private func refreshFirmwares() {
        Task { await loadFirmwares(for: selectedDeviceID) }
    }

    private func clearFirmwareSelection() {
        firmwareOptions = []
        selectedFirmwareID = ""
        firmwareSource = ""
        firmwareStatus = "Pulsa Reload para cargar firmwares desde IPSW.me o pega una URL/ruta IPSW manualmente."
    }

    @MainActor
    private func loadFirmwares(for deviceID: String) async {
        firmwareStatus = "Cargando firmwares para \(deviceID)..."
        firmwareOptions = []
        selectedFirmwareID = ""
        firmwareSource = ""

        guard let url = URL(string: "https://api.ipsw.me/v4/device/\(deviceID)?type=ipsw") else {
            firmwareStatus = "No se pudo formar la URL de IPSW.me."
            return
        }

        do {
            let (data, response) = try await URLSession.shared.compatibilityData(from: url)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw AppError.network("IPSW.me no respondió correctamente.")
            }

            let deviceResponse = try JSONDecoder().decode(IPSWDeviceResponse.self, from: data)
            firmwareOptions = deviceResponse.firmwares.sorted { lhs, rhs in
                lhs.releaseDate > rhs.releaseDate
            }

            selectedFirmwareID = visibleFirmwares.first?.id ?? firmwareOptions.first?.id ?? ""
            applySelectedFirmwareURL()
            firmwareStatus = firmwareOptions.isEmpty ? "IPSW.me no devolvió firmwares para \(deviceID)." : "\(firmwareOptions.count) firmwares cargados desde IPSW.me."
        } catch {
            firmwareStatus = firmwareLoadErrorMessage(for: error)
        }
    }

    private func firmwareLoadErrorMessage(for error: Error) -> String {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotFindHost {
            return "No se pudo resolver api.ipsw.me. Revisa Internet y activa Network > Outgoing Connections (Client) en Signing & Capabilities."
        }

        return "No se pudieron cargar firmwares: \(error.localizedDescription)"
    }

    private func applySelectedFirmwareURL() {
        guard let firmware = firmwareOptions.first(where: { $0.id == selectedFirmwareID }) else { return }
        firmwareSource = firmware.url.absoluteString
    }

    private func startPreparation() {
        let missingFields = requiredFields.filter { $0.value.trimmed.isEmpty }

        guard missingFields.isEmpty else {
            workflowState = .failed("Falta: " + missingFields.map(\.name).joined(separator: ", "))
            return
        }

        workflowTask?.cancel()
        completedStages = []
        logs = []
        artifactBundle = ArtifactBundle.empty
        workflowState = .running
        appendLog("Preparando paquete para \(selectedDevice.displayName).")

        workflowTask = Task {
            await runPreparation()
        }
    }

    @MainActor
    private func runPreparation() async {
        do {
            var context = PreparationContext(workURL: URL(fileURLWithPath: workFolder.trimmed, isDirectory: true))

            for stage in WorkflowStage.allCases {
                guard !Task.isCancelled else {
                    workflowState = .cancelled
                    appendLog("Preparación cancelada por el usuario.")
                    return
                }

                currentStage = stage
                appendLog(stage.startMessage)
                try await perform(stage, context: &context)
                completedStages.insert(stage)
                appendLog(stage.finishMessage)
            }

            artifactBundle = context.bundle
            currentStage = nil
            workflowState = .completed
            appendLog("Paquete listo para usarse con otras herramientas.")
        } catch is CancellationError {
            workflowState = .cancelled
            appendLog("Preparación cancelada.")
        } catch {
            currentStage = nil
            workflowState = .failed(error.localizedDescription)
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func perform(_ stage: WorkflowStage, context: inout PreparationContext) async throws {
        switch stage {
        case .validateInputs:
            try validateInputs()
            try await shortDelay()
        case .acquireFirmware:
            context.ipswURL = try await resolveFirmware(in: context.workURL)
        case .prepareWorkspace:
            context.bundle = try prepareWorkspace(at: context.workURL, ipswURL: context.ipswURL)
            try extractStockArtifacts(from: context.ipswURL, into: context.bundle)
        case .writeManifest:
            try writeManifest(to: URL(fileURLWithPath: context.bundle.manifestPath), ipswURL: context.ipswURL)
        case .writeBuildScript:
            let script = makeBuildScript(bundle: context.bundle, ipswURL: context.ipswURL)
            try writeExecutableScript(script, to: URL(fileURLWithPath: context.bundle.scriptPath))
        case .finalizePackage:
            try finalizeDeviceOutput(context.bundle)
            try await shortDelay()
        }
    }

    private func validateInputs() throws {
        guard URL(string: firmwareSource.trimmed) != nil || FileManager.default.fileExists(atPath: firmwareSource.trimmed) else {
            throw AppError.validation("La URL o ruta IPSW no es válida.")
        }

        guard !workFolder.trimmed.contains("\n") else {
            throw AppError.validation("La carpeta de trabajo contiene caracteres inválidos.")
        }
    }

    private func shortDelay() async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    @MainActor
    private func resolveFirmware(in workURL: URL) async throws -> URL {
        let source = firmwareSource.trimmed
        let fileManager = FileManager.default
        let ipswDirectory = workURL.appendingPathComponent("ipsw", isDirectory: true)

        try fileManager.createDirectory(at: ipswDirectory, withIntermediateDirectories: true)

        if let remoteURL = URL(string: source), let scheme = remoteURL.scheme, scheme.hasPrefix("http") {
            let destination = ipswDirectory.appendingPathComponent(remoteURL.lastPathComponent.isEmpty ? "firmware.ipsw" : remoteURL.lastPathComponent)

            if fileManager.fileExists(atPath: destination.path) {
                appendLog("IPSW ya existe: \(destination.path)")
                return destination
            }

            appendLog("Descargando IPSW público...")
            let (temporaryURL, response) = try await URLSession.shared.compatibilityDownload(from: remoteURL)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw AppError.network("La descarga del IPSW falló.")
            }

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            try fileManager.moveItem(at: temporaryURL, to: destination)
            appendLog("IPSW guardado en: \(destination.path)")
            return destination
        }

        let localURL = URL(fileURLWithPath: source)
        guard fileManager.fileExists(atPath: localURL.path) else {
            throw AppError.validation("La ruta IPSW local no existe.")
        }

        appendLog("Usando IPSW local: \(localURL.path)")
        return localURL
    }

    private func prepareWorkspace(at workURL: URL, ipswURL: URL) throws -> ArtifactBundle {
        let fileManager = FileManager.default
        let buildURL = workURL.appendingPathComponent("build", isDirectory: true)
        let componentsURL = workURL.appendingPathComponent("components", isDirectory: true)
        let ramdiskRootURL = workURL.appendingPathComponent("ramdisk_root", isDirectory: true)
        let scriptsURL = workURL.appendingPathComponent("scripts", isDirectory: true)
        let deviceOutputURL = workURL.appendingPathComponent(selectedDevice.id, isDirectory: true)
        let ramdiskImageURL = buildURL.appendingPathComponent("ramdisk.dmg")
        let manifestURL = buildURL.appendingPathComponent("manifest.json")
        let scriptURL = scriptsURL.appendingPathComponent("create_ramdisk.zsh")

        for directory in [workURL, buildURL, componentsURL, ramdiskRootURL, scriptsURL, deviceOutputURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if includeSSH {
            try fileManager.createDirectory(at: ramdiskRootURL.appendingPathComponent("usr/local/bin", isDirectory: true), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: ramdiskRootURL.appendingPathComponent("etc/dropbear", isDirectory: true), withIntermediateDirectories: true)
        }

        let bundle = ArtifactBundle(
            workPath: workURL.path,
            deviceOutputPath: deviceOutputURL.path,
            ipswPath: ipswURL.path,
            componentsPath: componentsURL.path,
            ramdiskRootPath: ramdiskRootURL.path,
            ramdiskImagePath: ramdiskImageURL.path,
            bootLogoPath: deviceOutputURL.appendingPathComponent("bootlogo.img4").path,
            deviceTreePath: deviceOutputURL.appendingPathComponent("devicetree.\(selectedDevice.id).img4").path,
            iBECPath: deviceOutputURL.appendingPathComponent("ibec.\(selectedDevice.id).img4").path,
            iBSSPath: deviceOutputURL.appendingPathComponent("ibss.\(selectedDevice.id).img4").path,
            kernelPath: deviceOutputURL.appendingPathComponent("kernel.\(selectedDevice.id).img4").path,
            ramdiskPath: deviceOutputURL.appendingPathComponent("ramdisk.\(selectedDevice.id).img4").path,
            shshPath: deviceOutputURL.appendingPathComponent("shsh.shsh").path,
            manifestPath: manifestURL.path,
            scriptPath: scriptURL.path
        )

        appendLog("Estructura creada en: \(workURL.path)")
        return bundle
    }

    private func extractStockArtifacts(from ipswURL: URL, into bundle: ArtifactBundle) throws {
        let extractionURL = URL(fileURLWithPath: bundle.workPath, isDirectory: true)
            .appendingPathComponent("extracted_ipsw", isDirectory: true)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: extractionURL.path) {
            try fileManager.removeItem(at: extractionURL)
        }

        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)
        try runProcess(executable: "/usr/bin/unzip", arguments: ["-qq", "-o", ipswURL.path, "-d", extractionURL.path])

        let extractedFiles = try collectFiles(in: extractionURL)
        let mappings: [(ArtifactKind, String)] = [
            (.ibss, bundle.iBSSPath),
            (.ibec, bundle.iBECPath),
            (.deviceTree, bundle.deviceTreePath),
            (.kernel, bundle.kernelPath),
            (.ramdisk, bundle.ramdiskPath),
            (.bootLogo, bundle.bootLogoPath),
            (.shsh, bundle.shshPath)
        ]

        for (kind, destinationPath) in mappings {
            guard let sourceURL = bestMatch(for: kind, in: extractedFiles) else {
                appendLog("No encontrado en IPSW: \(kind.displayName)")
                continue
            }

            let destinationURL = URL(fileURLWithPath: destinationPath)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.copyItem(at: sourceURL, to: destinationURL)

            let componentCopyURL = URL(fileURLWithPath: bundle.componentsPath, isDirectory: true)
                .appendingPathComponent(sourceURL.lastPathComponent)
            if !fileManager.fileExists(atPath: componentCopyURL.path) {
                try fileManager.copyItem(at: sourceURL, to: componentCopyURL)
            }

            appendLog("Extraido: \(destinationURL.lastPathComponent) desde \(sourceURL.lastPathComponent)")
        }
    }

    private func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmed
            throw AppError.validation(message?.isEmpty == false ? message! : "Falló \(executable).")
        }
    }

    private func collectFiles(in directory: URL) throws -> [URL] {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: resourceKeys) else {
            return []
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            return values.isRegularFile == true ? url : nil
        }
    }

    private func bestMatch(for kind: ArtifactKind, in files: [URL]) -> URL? {
        files
            .map { (url: $0, score: matchScore(for: kind, url: $0)) }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.url.path.count < rhs.url.path.count
                }
                return lhs.score > rhs.score
            }
            .first?
            .url
    }

    private func matchScore(for kind: ArtifactKind, url: URL) -> Int {
        let fileName = url.lastPathComponent.lowercased()
        let path = url.path.lowercased()
        var score = 0

        for pattern in kind.fallbackPatterns where fileName.contains(pattern) || path.contains(pattern) {
            score += 10
        }

        for pattern in kind.preferredPatterns where fileName.contains(pattern) || path.contains(pattern) {
            score += 20
        }

        if path.contains("/firmware/dfu/") {
            switch kind {
            case .ibss, .ibec:
                score += 40
            default:
                break
            }
        }

        if fileName.hasPrefix(kind.filePrefix) {
            score += 50
        }

        if fileName.hasSuffix(".im4p") || fileName.hasSuffix(".img4") {
            score += 8
        }

        if fileName.contains("release") {
            score += 4
        }

        return score
    }

    private func writeManifest(to manifestURL: URL, ipswURL: URL) throws {
        let manifest = BuildManifest(
            deviceIdentifier: selectedDevice.id,
            deviceName: selectedDevice.name,
            chip: selectedDevice.chip,
            firmwareVersion: selectedFirmware?.version ?? "manual",
            firmwareBuild: selectedFirmware?.buildid ?? "manual",
            firmwareURL: firmwareSource.trimmed,
            ipswPath: ipswURL.path,
            keySource: keySource.trimmed,
            bootArguments: bootArguments.trimmed,
            ramdiskSizeMB: ramdiskSizeMB,
            includeSSH: includeSSH,
            generatedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        appendLog("Manifest escrito: \(manifestURL.path)")
    }

    private func writeExecutableScript(_ script: String, to scriptURL: URL) throws {
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        appendLog("Script escrito: \(scriptURL.path)")
    }

    private func finalizeDeviceOutput(_ bundle: ArtifactBundle) throws {
        let fileManager = FileManager.default
        let outputURL = URL(fileURLWithPath: bundle.deviceOutputPath, isDirectory: true)
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

        var missingFiles: [String] = []

        for artifact in bundle.expectedArtifacts {
            let destination = URL(fileURLWithPath: artifact.path)

            if fileManager.fileExists(atPath: destination.path) {
                continue
            }

            if let source = findCandidate(for: artifact.fileName, in: bundle) {
                try fileManager.copyItem(at: source, to: destination)
                appendLog("Copiado: \(destination.lastPathComponent)")
            } else {
                missingFiles.append(artifact.fileName)
            }
        }

        let requiredFilesURL = outputURL.appendingPathComponent("required_files.txt")
        let requiredText = missingFiles.isEmpty
            ? "Todos los artefactos esperados estan presentes.\n"
            : missingFiles.map { "Falta: \($0)" }.joined(separator: "\n") + "\n"
        try requiredText.write(to: requiredFilesURL, atomically: true, encoding: .utf8)

        let readmeURL = outputURL.appendingPathComponent("README.md")
        try outputReadme(for: bundle, missingFiles: missingFiles).write(to: readmeURL, atomically: true, encoding: .utf8)

        if missingFiles.isEmpty {
            appendLog("Carpeta final completa: \(bundle.deviceOutputPath)")
        } else {
            appendLog("Carpeta final creada con \(missingFiles.count) artefactos pendientes.")
        }
    }

    private func findCandidate(for fileName: String, in bundle: ArtifactBundle) -> URL? {
        let fileManager = FileManager.default
        let searchRoots = [bundle.componentsPath, bundle.workPath, URL(fileURLWithPath: bundle.ramdiskImagePath).deletingLastPathComponent().path]

        for root in searchRoots {
            let directURL = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: directURL.path) {
                return directURL
            }
        }

        return nil
    }

    private func outputReadme(for bundle: ArtifactBundle, missingFiles: [String]) -> String {
        [
            "# \(selectedDevice.id)",
            "",
            "Esta carpeta es la salida final para herramientas externas que esperan artefactos por modelo.",
            "",
            "## Archivos esperados",
            bundle.expectedArtifacts.map { "- \($0.fileName)" }.joined(separator: "\n"),
            "",
            "## Estado",
            missingFiles.isEmpty ? "Completo." : missingFiles.map { "Pendiente: \($0)" }.joined(separator: "\n"),
            "",
            "Holly Maker RamDisk extrae componentes stock del IPSW cuando existen y no crea IMG4 falsos. Si un artefacto requiere descifrado, parcheo o firma externa, aparecera como pendiente."
        ].joined(separator: "\n")
    }

    private func makeBuildScript(bundle: ArtifactBundle, ipswURL: URL) -> String {
        let tools = shellEscaped(toolsFolder.trimmed)
        let ipsw = shellEscaped(ipswURL.path)
        let components = shellEscaped(bundle.componentsPath)
        let ramdiskRoot = shellEscaped(bundle.ramdiskRootPath)
        let ramdiskImage = shellEscaped(bundle.ramdiskImagePath)
        let output = shellEscaped(bundle.deviceOutputPath)
        let keyDescription = shellEscaped(keySource.trimmed)
        let sshStep = includeSSH ? "echo 'SSH: coloca tus binarios/configuracion en ramdisk_root/usr/local/bin y ramdisk_root/etc/dropbear'" : "echo 'SSH desactivado'"

        return [
            "#!/bin/zsh",
            "set -euo pipefail",
            "TOOLS=\(tools)",
            "IPSW=\(ipsw)",
            "COMPONENTS=\(components)",
            "RAMDISK_ROOT=\(ramdiskRoot)",
            "RAMDISK_IMAGE=\(ramdiskImage)",
            "OUTPUT=\(output)",
            "KEY_SOURCE=\(keyDescription)",
            "mkdir -p \"$COMPONENTS\" \"$RAMDISK_ROOT\" \"$OUTPUT\"",
            "echo '1/5 Extrae componentes necesarios desde el IPSW'",
            "echo '   Usa pzb, unzip u otra herramienta compatible segun tu flujo.'",
            "echo '2/5 Descifra componentes con las llaves del usuario'",
            "echo '   Herramientas esperadas: img4/xpwntool u otra equivalente.'",
            "echo '3/5 Prepara contenido del ramdisk'",
            sshStep,
            "echo '4/5 Crea imagen HFS+ del ramdisk'",
            "hdiutil create -ov -size \(ramdiskSizeMB)m -fs HFS+ -volname HollyRamDisk \"$RAMDISK_IMAGE\"",
            "MOUNT_POINT=$(hdiutil attach \"$RAMDISK_IMAGE\" | awk '/HollyRamDisk/ {print $3; exit}')",
            "cp -R \"$RAMDISK_ROOT\"/* \"$MOUNT_POINT\"/ 2>/dev/null || true",
            "hdiutil detach \"$MOUNT_POINT\"",
            "echo '5/5 Coloca o genera los artefactos finales con estos nombres:'",
            "cat > \"$OUTPUT/required_files.txt\" <<'EOF'",
            "bootlogo.img4",
            "devicetree.\(selectedDevice.id).img4",
            "ibec.\(selectedDevice.id).img4",
            "ibss.\(selectedDevice.id).img4",
            "kernel.\(selectedDevice.id).img4",
            "ramdisk.\(selectedDevice.id).img4",
            "shsh.shsh",
            "EOF",
            "cat \"$OUTPUT/required_files.txt\"",
            "echo 'Boot args sugeridos: \(bootArguments.trimmed)'"
        ].joined(separator: "\n")
    }

    private func cancelPreparation() {
        workflowTask?.cancel()
        workflowTask = nil

        if isRunning {
            workflowState = .cancelled
            appendLog("Preparación cancelada.")
        }
    }

    private func resetPreparation() {
        workflowTask?.cancel()
        workflowTask = nil
        workflowState = .idle
        currentStage = nil
        completedStages = []
        logs = []
        artifactBundle = .empty
    }

    private func appendLog(_ message: String) {
        logs.append(LogEntry(message: message))
    }

    private var requiredFields: [(name: String, value: String)] {
        [
            ("dispositivo", selectedDeviceID),
            ("IPSW", firmwareSource),
            ("carpeta", workFolder),
            ("llaves", keySource),
            ("herramientas", toolsFolder)
        ]
    }

    private func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct ArtifactDashboard: View {
    let state: WorkflowState
    let currentStage: WorkflowStage?
    let completedStages: Set<WorkflowStage>
    let progress: Double
    let logs: [LogEntry]
    let artifactBundle: ArtifactBundle

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            statusHeader
            stageList
            outputView
            logView
        }
        .panelStyle()
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                PanelTitle(title: L10n.text("panel.artifacts", "Artifacts"), systemImage: "shippingbox")
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.headline.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            ProgressView(value: progress)
    
            if let message = state.message {
                Text(message)
                    .font(.callout)
                    .foregroundColor(state.isFailure ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("panel.stages", "Stages"))
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(WorkflowStage.allCases) { stage in
                    StageRow(
                        stage: stage,
                        isCurrent: currentStage == stage,
                        isCompleted: completedStages.contains(stage)
                    )

                    if stage != WorkflowStage.allCases.last {
                        Divider()
                            .padding(.leading, 34)
                    }
                }
            }
        }
    }

    private var outputView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("panel.preparedOutput", "Prepared output"))
                .font(.headline)

            ScrollView(.horizontal) {
                Text(artifactBundle.description)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
                    .frame(minHeight: 160, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("panel.logs", "Logs"))
                .font(.headline)

            ScrollView(.horizontal) {
                Text(logText)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
                    .frame(minHeight: 110, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
        }
    }

    private var logText: String {
        guard !logs.isEmpty else { return L10n.text("logs.empty", "Events will appear when preparing artifacts.") }
        return logs.map { "[\($0.time)] \($0.message)" }.joined(separator: "\n")
    }
}

private struct StageRow: View {
    let stage: WorkflowStage
    let isCurrent: Bool
    let isCompleted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(stage.title)
                    .font(.subheadline.weight(.semibold))

                Text(stage.detail)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
    }

    private var iconName: String {
        if isCompleted { return "checkmark.circle.fill" }
        if isCurrent { return "arrow.triangle.2.circlepath.circle.fill" }
        return "circle"
    }

    private var iconColor: Color {
        if isCompleted { return .green }
        if isCurrent { return .blue }
        return .secondary
    }
}

private struct FieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var isDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .disabled(isDisabled)
        }
    }
}

private struct SecureFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var isDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            SecureField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .disabled(isDisabled)
        }
    }
}

private struct FirmwareSummary: View {
    let firmware: IPSWFirmware

    var body: some View {
        HStack(spacing: 12) {
            Label(firmware.signed ? "Firmado" : "No firmado", systemImage: firmware.signed ? "checkmark.seal.fill" : "xmark.seal")
                .foregroundColor(firmware.signed ? .green : .secondary)

            Text(firmware.humanReleaseDate)
                .foregroundColor(.secondary)
        }
        .font(.footnote)
    }
}

private struct PanelTitle: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.title3.bold())
    }
}

private struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.16), lineWidth: 1))
    }
}

private extension View {
    func panelStyle() -> some View {
        modifier(PanelStyle())
    }
}

private enum ArtifactKind {
    case ibss
    case ibec
    case deviceTree
    case kernel
    case ramdisk
    case bootLogo
    case shsh

    var displayName: String {
        switch self {
        case .ibss:
            "iBSS"
        case .ibec:
            "iBEC"
        case .deviceTree:
            "DeviceTree"
        case .kernel:
            "kernelcache"
        case .ramdisk:
            "RestoreRamDisk"
        case .bootLogo:
            "bootlogo"
        case .shsh:
            "SHSH"
        }
    }

    var preferredPatterns: [String] {
        switch self {
        case .ibss:
            ["ibss"]
        case .ibec:
            ["ibec"]
        case .deviceTree:
            ["devicetree"]
        case .kernel:
            ["kernelcache"]
        case .ramdisk:
            ["restoreramdisk"]
        case .bootLogo:
            ["applelogo"]
        case .shsh:
            ["shsh"]
        }
    }

    var fallbackPatterns: [String] {
        switch self {
        case .ibss:
            ["ibss"]
        case .ibec:
            ["ibec"]
        case .deviceTree:
            ["devicetree"]
        case .kernel:
            ["kernel"]
        case .ramdisk:
            ["ramdisk", "restore"]
        case .bootLogo:
            ["bootlogo", "logo"]
        case .shsh:
            ["shsh"]
        }
    }

    var filePrefix: String {
        switch self {
        case .ibss:
            "ibss"
        case .ibec:
            "ibec"
        case .deviceTree:
            "devicetree"
        case .kernel:
            "kernel"
        case .ramdisk:
            "restoreramdisk"
        case .bootLogo:
            "applelogo"
        case .shsh:
            "shsh"
        }
    }
}

private struct PreparationContext {
    let workURL: URL
    var ipswURL: URL = URL(fileURLWithPath: "/")
    var bundle = ArtifactBundle.empty
}

private struct ArtifactBundle: Equatable {
    let workPath: String
    let deviceOutputPath: String
    let ipswPath: String
    let componentsPath: String
    let ramdiskRootPath: String
    let ramdiskImagePath: String
    let bootLogoPath: String
    let deviceTreePath: String
    let iBECPath: String
    let iBSSPath: String
    let kernelPath: String
    let ramdiskPath: String
    let shshPath: String
    let manifestPath: String
    let scriptPath: String

    static let empty = ArtifactBundle(
        workPath: "",
        deviceOutputPath: "",
        ipswPath: "",
        componentsPath: "",
        ramdiskRootPath: "",
        ramdiskImagePath: "",
        bootLogoPath: "",
        deviceTreePath: "",
        iBECPath: "",
        iBSSPath: "",
        kernelPath: "",
        ramdiskPath: "",
        shshPath: "",
        manifestPath: "",
        scriptPath: ""
    )

    var expectedArtifacts: [ExpectedArtifact] {
        [
            ExpectedArtifact(fileName: URL(fileURLWithPath: bootLogoPath).lastPathComponent, path: bootLogoPath),
            ExpectedArtifact(fileName: URL(fileURLWithPath: deviceTreePath).lastPathComponent, path: deviceTreePath),
            ExpectedArtifact(fileName: URL(fileURLWithPath: iBECPath).lastPathComponent, path: iBECPath),
            ExpectedArtifact(fileName: URL(fileURLWithPath: iBSSPath).lastPathComponent, path: iBSSPath),
            ExpectedArtifact(fileName: URL(fileURLWithPath: kernelPath).lastPathComponent, path: kernelPath),
            ExpectedArtifact(fileName: URL(fileURLWithPath: ramdiskPath).lastPathComponent, path: ramdiskPath),
            ExpectedArtifact(fileName: URL(fileURLWithPath: shshPath).lastPathComponent, path: shshPath)
        ]
    }

    var description: String {
        guard !workPath.isEmpty else {
            return "Aun no hay artefactos. Presiona Preparar artefactos para crear la carpeta final del dispositivo."
        }

        return [
            "Carpeta final: \(deviceOutputPath)",
            "bootlogo.img4: \(bootLogoPath)",
            "devicetree: \(deviceTreePath)",
            "iBEC: \(iBECPath)",
            "iBSS: \(iBSSPath)",
            "kernel: \(kernelPath)",
            "ramdisk: \(ramdiskPath)",
            "SHSH: \(shshPath)",
            "",
            "Workdir: \(workPath)",
            "IPSW: \(ipswPath)",
            "Componentes: \(componentsPath)",
            "Root ramdisk: \(ramdiskRootPath)",
            "DMG temporal: \(ramdiskImagePath)",
            "Manifest: \(manifestPath)",
            "Script: \(scriptPath)"
        ].joined(separator: "\n")
    }
}

private struct ExpectedArtifact: Equatable {
    let fileName: String
    let path: String
}

private struct BuildManifest: Encodable {
    let deviceIdentifier: String
    let deviceName: String
    let chip: String
    let firmwareVersion: String
    let firmwareBuild: String
    let firmwareURL: String
    let ipswPath: String
    let keySource: String
    let bootArguments: String
    let ramdiskSizeMB: Int
    let includeSSH: Bool
    let generatedAt: Date
}

private struct SupportedDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let chip: String

    var displayName: String {
        "\(name) · \(id) · \(chip)"
    }

    static let compatible = [
        SupportedDevice(id: "iPhone9,1", name: "iPhone 7", chip: "A10"),
        SupportedDevice(id: "iPhone9,2", name: "iPhone 7 Plus", chip: "A10"),
        SupportedDevice(id: "iPhone9,3", name: "iPhone 7", chip: "A10"),
        SupportedDevice(id: "iPhone9,4", name: "iPhone 7 Plus", chip: "A10"),
        SupportedDevice(id: "iPhone10,1", name: "iPhone 8", chip: "A11"),
        SupportedDevice(id: "iPhone10,2", name: "iPhone 8 Plus", chip: "A11"),
        SupportedDevice(id: "iPhone10,3", name: "iPhone X", chip: "A11"),
        SupportedDevice(id: "iPhone10,4", name: "iPhone 8", chip: "A11"),
        SupportedDevice(id: "iPhone10,5", name: "iPhone 8 Plus", chip: "A11"),
        SupportedDevice(id: "iPhone10,6", name: "iPhone X", chip: "A11"),
        SupportedDevice(id: "iPhone11,2", name: "iPhone XS", chip: "A12"),
        SupportedDevice(id: "iPhone11,4", name: "iPhone XS Max", chip: "A12"),
        SupportedDevice(id: "iPhone11,6", name: "iPhone XS Max", chip: "A12"),
        SupportedDevice(id: "iPhone11,8", name: "iPhone XR", chip: "A12"),
        SupportedDevice(id: "iPhone12,1", name: "iPhone 11", chip: "A13"),
        SupportedDevice(id: "iPhone12,3", name: "iPhone 11 Pro", chip: "A13"),
        SupportedDevice(id: "iPhone12,5", name: "iPhone 11 Pro Max", chip: "A13"),
        SupportedDevice(id: "iPhone12,8", name: "iPhone SE 2", chip: "A13")
    ]
}

private struct IPSWDeviceResponse: Decodable {
    let firmwares: [IPSWFirmware]
}

private struct IPSWFirmware: Decodable, Identifiable {
    let version: String
    let buildid: String
    let url: URL
    let signed: Bool
    let releasedate: String?

    var id: String {
        "\(version)-\(buildid)"
    }

    var releaseDate: Date {
        guard let releasedate else { return .distantPast }
        return Self.isoFormatter.date(from: releasedate) ?? .distantPast
    }

    var humanReleaseDate: String {
        guard releaseDate != .distantPast else { return "Fecha desconocida" }
        return Self.displayFormatter.string(from: releaseDate)
    }

    var displayName: String {
        let signing = signed ? "firmado" : "no firmado"
        return "iOS \(version) (\(buildid)) · \(signing)"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private enum WorkflowState: Equatable {
    case idle
    case running
    case completed
    case cancelled
    case failed(String)

    var message: String? {
        switch self {
        case .idle:
            L10n.text("state.idle", "Configure the package and press Prepare artifacts.")
        case .running:
            L10n.text("state.running", "Preparing local ramdisk files.")
        case .completed:
            L10n.text("state.completed", "Artifacts are ready for use with other tools.")
        case .cancelled:
            L10n.text("state.cancelled", "Preparation was stopped before finishing.")
        case .failed(let message):
            message
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private enum WorkflowStage: String, CaseIterable, Identifiable {
    case validateInputs
    case acquireFirmware
    case prepareWorkspace
    case writeManifest
    case writeBuildScript
    case finalizePackage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .validateInputs:
            L10n.text("stage.validateInputs.title", "Validate input")
        case .acquireFirmware:
            L10n.text("stage.acquireFirmware.title", "Get IPSW")
        case .prepareWorkspace:
            L10n.text("stage.prepareWorkspace.title", "Create structure")
        case .writeManifest:
            L10n.text("stage.writeManifest.title", "Create manifest")
        case .writeBuildScript:
            L10n.text("stage.writeBuildScript.title", "Create script")
        case .finalizePackage:
            L10n.text("stage.finalizePackage.title", "Finalize package")
        }
    }

    var detail: String {
        switch self {
        case .validateInputs:
            L10n.text("stage.validateInputs.detail", "Checks model, firmware, folder, keys, and tools.")
        case .acquireFirmware:
            L10n.text("stage.acquireFirmware.detail", "Downloads the selected public IPSW or validates a local path.")
        case .prepareWorkspace:
            L10n.text("stage.prepareWorkspace.detail", "Creates component, ramdisk root, script, and build folders.")
        case .writeManifest:
            L10n.text("stage.writeManifest.detail", "Saves reproducible metadata for the work package.")
        case .writeBuildScript:
            L10n.text("stage.writeBuildScript.detail", "Generates the local script for building ramdisk.dmg.")
        case .finalizePackage:
            L10n.text("stage.finalizePackage.detail", "Leaves output paths ready for external tools.")
        }
    }

    var startMessage: String {
        "Iniciando: \(title)."
    }

    var finishMessage: String {
        "Terminado: \(title)."
    }
}

private struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String

    var time: String {
        Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private enum AppError: LocalizedError {
    case network(String)
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .network(let message), .validation(let message):
            message
        }
    }
}

private extension URLSession {
    func compatibilityData(from url: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = dataTask(with: url) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, let response else {
                    continuation.resume(throwing: AppError.network("No response data was received."))
                    return
                }

                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }

    func compatibilityDownload(from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = downloadTask(with: url) { temporaryURL, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let temporaryURL, let response else {
                    continuation.resume(throwing: AppError.network("No downloaded file was received."))
                    return
                }

                continuation.resume(returning: (temporaryURL, response))
            }
            task.resume()
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    ContentView()
}
