//
//  LCContainerView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/12/6.
//

import SwiftUI

protocol LCContainerViewDelegate {
    func unbindContainer(container: LCContainer)
    func setDefaultContainer(container: LCContainer)
    func saveContainer(container: LCContainer)
    
    func getSettingsBundle() -> Bundle?
    func getContainerURL(container: LCContainer) -> URL
    func getBundleId() -> String
}

struct LCContainerView : View {
    @ObservedObject var container : LCContainer
    let delegate : LCContainerViewDelegate
    @Binding var uiDefaultDataFolder : String?
    @State var settingsBundle : Bundle? = nil
    
    @StateObject private var removeContainerAlert = YesNoHelper()
    @StateObject private var deleteDataAlert = YesNoHelper()
    @StateObject private var removeKeychainAlert = YesNoHelper()
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sharedModel : SharedModel
    @State private var typingContainerName : String = ""
    @State private var typingIDFV: String = ""
    @State private var inUse = false
    @State private var runningLC : String? = nil
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    @State private var successShow = false
    @State private var successInfo = ""
    
    init(container: LCContainer, uiDefaultDataFolder : Binding<String?>, delegate: LCContainerViewDelegate) {
        self._container = ObservedObject(initialValue: container)
        self.delegate = delegate
        self._typingContainerName = State(initialValue: container.name)
        self._uiDefaultDataFolder = Binding(projectedValue: uiDefaultDataFolder)
    }
    
    var body: some View {
        Form {
            if !(container.storageBookMark != nil && container.resolvedContainerURL == nil) {
                
                Section {
                    HStack {
                        Text("lc.container.containerName".loc)
                        Spacer()
                        TextField("lc.container.containerName".loc, text: $typingContainerName)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                container.name = typingContainerName
                                saveContainer()
                            }
                    }
                    HStack {
                        Text("lc.container.containerFolderName".loc)
                        Spacer()
                        Text(container.folderName)
                            .foregroundStyle(.gray)
                    }
                    Toggle(isOn: $container.isolateAppGroup) {
                        Text("lc.container.isolateAppGroup".loc)
                    }
                    .onChange(of: container.isolateAppGroup) { newValue in
                        saveContainer()
                    }
                    
                    if let settingsBundle {
                        NavigationLink {
                            AppPreferenceView(bundleId: delegate.getBundleId(), settingsBundle: settingsBundle, containerURL: delegate.getContainerURL(container: container))
                        } label: {
                            Text("lc.container.preferences".loc)
                        }
                    }
                    if container.folderName == uiDefaultDataFolder {
                        Text("lc.container.alreadyDefaultContainer".loc)
                            .foregroundStyle(.gray)
                    } else {
                        Button {
                            setAsDefault()
                        } label: {
                            Text("lc.container.setDefaultContainer".loc)
                        }
                    }
                } footer: {
                    Text("lc.container.defaultContainerDesc".loc)
                }
                
                Section {
                    Toggle(isOn: $container.spoofIdentifierForVendor) {
                        Text("lc.container.spoofIdentifierForVendor".loc)
                    }
                    .onChange(of: container.spoofIdentifierForVendor) { newValue in
                        saveContainer()
                    }
                    
                    if container.spoofIdentifierForVendor {
                        HStack {
                            Text("UUID")
                            TextField("lc.common.auto".loc, text: $typingIDFV)
                                .multilineTextAlignment(.trailing)
                                .onSubmit {
                                    saveIDFV()
                                }
                        }
                    }
                }

                Section {
                    if inUse {
                        Text("lc.container.inUse".loc)
                            .foregroundStyle(.gray)
                        
                    } else {
                        if !container.isShared || container.storageBookMark != nil {
                            Button {
                                openDataFolder()
                            } label: {
                                Text("lc.appBanner.openDataFolder".loc)
                            }
                            Button {
                                unbindContainer()
                            } label: {
                                Text("lc.container.unbind".loc)
                            }
                        }
                        Button(role:.destructive) {
                            Task { await deleteData() }
                        } label: {
                            Text("lc.container.deleteData".loc)
                        }
                        
                        Button(role:.destructive) {
                            Task { await cleanUpKeychain() }
                        } label: {
                            Text("lc.settings.cleanKeychain".loc)
                        }
                        
                        if(container.storageBookMark == nil) {
                            Button(role:.destructive) {
                                Task { await removeContainer() }
                            } label: {
                                Text("lc.container.removeContainer".loc)
                            }
                        }
                        
                    }
                }
            } else {
                Section {
                    if container.bookmarkResolved {
                        Text("lc.container.externalStorageUnavailable".loc)
                    } else {
                        Text("lc.container.bookmarkResolveInProgress".loc)
                    }

                }
                
                Section {
                    Button(role:.destructive) {
                        Task { await removeContainer() }
                    } label: {
                        Text("lc.container.removeContainer".loc)
                    }
                }
            }
        }
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("lc.common.error".loc, isPresented: $errorShow){
        } message: {
            Text(errorInfo)
        }
        .alert("lc.common.success".loc, isPresented: $successShow){
        } message: {
            Text(successInfo)
        }
        
        .alert("lc.container.removeContainer".loc, isPresented: $removeContainerAlert.show) {
            Button(role: .destructive) {
                removeContainerAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                removeContainerAlert.close(result: false)
            }
        } message: {
            Text("lc.container.removeContainerDesc".loc)
        }
        
        .alert("lc.container.deleteData".loc, isPresented: $deleteDataAlert.show) {
            Button(role: .destructive) {
                deleteDataAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                deleteDataAlert.close(result: false)
            }
        } message: {
            Text("lc.container.deleteDataDesc".loc)
        }
        
        .alert("lc.settings.cleanKeychain".loc, isPresented: $removeKeychainAlert.show) {
            Button(role: .destructive) {
                removeKeychainAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                removeKeychainAlert.close(result: false)
            }
        } message: {
            Text("lc.container.removeKeychainDesc".loc)
        }
        .onAppear() {
            container.reloadInfoPlist()
            if let spoofedIDFV = container.spoofedIdentifier {
                typingIDFV = spoofedIDFV
            }
            settingsBundle = delegate.getSettingsBundle()
            runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName)
            inUse = runningLC != nil
        }
        
    }
    
    func saveIDFV() {
        guard let newIDFV = UUID(uuidString: typingIDFV) else {
            errorInfo = "lc.container.invalidIDFV".loc
            errorShow = true
            return
        }
        container.spoofedIdentifier = newIDFV.uuidString
        delegate.saveContainer(container: container)
    }

    func saveContainer() {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        
        delegate.saveContainer(container: container)
    }
    
    func openDataFolder() {
        let url = URL(string:"shareddocuments://\(LCPath.dataPath.path)/\(container.folderName)")
        UIApplication.shared.open(url!)
    }
    
    func setAsDefault() {
        delegate.setDefaultContainer(container: container)
    }
    
    func removeContainer() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        guard let ans = await removeContainerAlert.open(), ans else {
            return
        }
        do {
            let fm = FileManager.default
            try fm.removeItem(at: container.containerURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
        
        dismiss()
        delegate.unbindContainer(container: container)
    }
    
    func unbindContainer() {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        
        dismiss()
        delegate.unbindContainer(container: container)
    }
    
    func cleanUpKeychain() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        guard let ans = await removeKeychainAlert.open(), ans else {
            return
        }
        
        LCUtils.removeAppKeychain(dataUUID: container.folderName)
    }
    
    func deleteData() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        guard let ans = await deleteDataAlert.open(), ans else {
            return
        }
        do {
            let fm = FileManager.default
            for file in try fm.contentsOfDirectory(at: container.containerURL, includingPropertiesForKeys: nil) {
                if file.lastPathComponent == "LCContainerInfo.plist" {
                    continue
                }
                try fm.removeItem(at: file)
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
}
