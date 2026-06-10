//
//  ContentView.swift
//  MathCanvas
//
//  Created by Jane on 2026/6/8.
//
//  目标：iPad 全屏 Apple Pencil 手写数学解题步骤。
//  右下角提供「服务 / 发送 / 清空」悬浮按钮。
//  点击「发送」将当前可见画面转成图片，并通过局域网 HTTP POST 发给 Mac。
//  服务地址可在 App 内直接修改，方便分享给朋友使用。
//

import SwiftUI
import PencilKit
import UIKit
import Combine

// MARK: - CanvasManager
/// 这个 ObservableObject 负责持有并管理 PKCanvasView（PencilKit 画布）。
/// 为什么需要它？
/// - SwiftUI 的 Button 需要调用「清空」「导出图片」等操作。
/// - 而 PKCanvasView 是 UIKit 组件，我们通过这个「桥梁」来间接操作它。
/// - 以后如果要做自动保存、监听笔迹变化，也方便在这里扩展。
final class CanvasManager: ObservableObject {
    /// 某些 Xcode 版本下，ObservableObject 的自动合成可能不稳定；
    /// 显式提供 objectWillChange 可以避免“未遵循协议”的编译误报。
    let objectWillChange = ObservableObjectPublisher()
    
    /// 核心画布视图（引用类型），我们只创建一次，终身持有。
    let canvasView: PKCanvasView = {
        let canvas = PKCanvasView()
        
        // 改成 .pencilOnly：Apple Pencil 负责书写，手指负责平移/缩放导航。
        // 这是无边记类应用最常见的交互方式。
        canvas.drawingPolicy = .pencilOnly
        
        // 背景设为纯白，导出图片时更干净（适合发给 Gemini 识别数学公式）。
        canvas.backgroundColor = .white
        
        // 设置默认绘图工具：
        // - .pen：钢笔，线条清晰，适合写公式和步骤
        // - color: .black：默认黑色墨迹
        // - width: 2.5：比较舒服的默认粗细（可通过工具选择器实时调节）
        canvas.tool = PKInkingTool(.pen, color: .black, width: 2.5)
        
        // 让画布不裁剪内容（写很长的解题过程也能保留）
        canvas.contentInset = .zero
        
        return canvas
    }()
    
    /// iOS 17+ 要求把 PKToolPicker 当作普通实例来持有，不再用已移除的 .shared 单例。
    /// 声明为属性是为了保住它的生命周期——如果它被释放，工具面板就会消失。
    private let toolPicker = PKToolPicker()
    
    /// 无边记式大小。
    /// 这个值越大，越像无限画布（不是诈骗！！！！！！同时不会真的产生巨量内存占用）。
    private let workspaceSize = CGSize(width: 20_000, height: 20_000)
    
    /// 只在首次布局时做一次无限画布初始化，避免每次刷新都重置缩放和位置。
    private var didConfigureInfiniteCanvas = false
    private var didAddToolPickerObserver = false
    
    // MARK: 清空画布
    /// 把画布上的所有笔迹清空，恢复空白状态。
    func clearCanvas() {
        // 直接给 drawing 赋一个新的空 PKDrawing 瞬间清空，不知道这样规不规范，但是好像很有效。
        canvasView.drawing = PKDrawing()
    }
    
    // MARK: 导出为 UIImage
    /// 把当前画布内容渲染成一张图片（带白色不透明背景）。
    /// 为什么要做这一步？
    /// - PencilKit 的 drawing 本身只是矢量数据。
    /// - 我们需要把它「拍成照片」一样的 UIImage，才能通过网络发送。
    /// - 这里固定使用画布的完整 bounds，保证每次导出的图片尺寸一致（便于后续服务端处理）。
    func exportAsImage() -> UIImage? {
        let bounds = canvasView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        
        // 关键：当画布支持缩放/平移后，导出应该以「当前可见区域」为准，
        // 否则会出现导出到固定左上角的错误内容。
        let zoomScale = max(canvasView.zoomScale, 0.0001)
        let visibleRectInCanvas = CGRect(
            x: canvasView.contentOffset.x / zoomScale,
            y: canvasView.contentOffset.y / zoomScale,
            width: bounds.width / zoomScale,
            height: bounds.height / zoomScale
        )
        let localRect = CGRect(origin: .zero, size: bounds.size)
        
        // UIGraphicsImageRenderer 是 iOS 17+ 推荐的现代渲染 API，
        // 会自动处理 Retina 屏 scale，比旧版 UIGraphicsBeginImageContextWithOptions 更安全。
        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        let finalImage = renderer.image { _ in
            // 1. 先用纯白色填充整个画布区域
            UIColor.white.setFill()
            UIRectFill(localRect)
            
            // 2. 把 PencilKit 里所有的笔迹（drawing）画到这个白色背景上
            //    drawing.image(from:scale:) 能高效渲染矢量笔迹为位图
            let scale = UIScreen.main.scale
            let drawingImage = canvasView.drawing.image(from: visibleRectInCanvas, scale: scale)
            drawingImage.draw(in: localRect)
        }
        
        return finalImage
    }
    
    // MARK: 发送图片到服务端（HTTP POST）
    /// 把导出的 UIImage 通过局域网发送给 Mac。
    /// 当前协议非常简单：
    /// - Method: POST
    /// - Content-Type: image/jpeg
    /// - Body: JPEG 二进制数据
    /// - URL: uploadEndpoint（例如 http://192.168.31.101:8765/upload）
    ///
    /// - Parameter image: 已经渲染好的完整截图
    /// - Parameter completion: 主线程回调，success 表示 HTTP 2xx
    func sendImageToServer(image: UIImage, completion: ((Bool, String) -> Void)? = nil) {
        let uploadEndpoint = currentUploadEndpoint()
        
        guard let url = URL(string: uploadEndpoint) else {
            let message = "服务地址不是合法 URL"
            print("【MathCanvas】发送失败：uploadEndpoint 不是合法 URL -> \(uploadEndpoint)")
            DispatchQueue.main.async { completion?(false, message) }
            return
        }
        
        // 用 JPEG 可以显著减小体积，网络发送更快。
        // 数学手写场景通常黑白为主，压缩质量 0.9所以已经非常清晰。
        guard let jpegData = image.jpegData(compressionQuality: 0.9) else {
            let message = "图片转换失败"
            print("【MathCanvas】发送失败：UIImage 转 JPEG 失败")
            DispatchQueue.main.async { completion?(false, message) }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("MathCanvas-iPad", forHTTPHeaderField: "X-Client-Name")
        
        print("【MathCanvas】开始发送：\(jpegData.count) bytes -> \(uploadEndpoint)")
        
        URLSession.shared.uploadTask(with: request, from: jpegData) { data, response, error in
            if let error {
                let message = Self.friendlyNetworkError(error)
                print("【MathCanvas】发送失败：\(message)")
                DispatchQueue.main.async { completion?(false, message) }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                let message = "未收到 HTTP 响应"
                print("【MathCanvas】发送失败：没有收到 HTTP 响应")
                DispatchQueue.main.async { completion?(false, message) }
                return
            }
            
            let responseText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if (200...299).contains(httpResponse.statusCode) {
                print("【MathCanvas】发送成功：status=\(httpResponse.statusCode) \(responseText)")
                DispatchQueue.main.async { completion?(true, "已发送到 Mac ✓") }
            } else {
                let message = "HTTP \(httpResponse.statusCode)"
                print("【MathCanvas】发送失败：status=\(httpResponse.statusCode) \(responseText)")
                DispatchQueue.main.async { completion?(false, message) }
            }
        }.resume()
    }
    
    // MARK: 服务地址设置（给分享版本用）
    /// 当前生效的服务地址（保存在 UserDefaults）。
    /// 没有保存过时，自动回落到 AppConfig.defaultUploadEndpoint。
    func currentUploadEndpoint() -> String {
        let saved = UserDefaults.standard.string(forKey: AppConfig.uploadEndpointKey)
        return saved ?? AppConfig.defaultUploadEndpoint
    }
    
    /// 更新服务地址（会去掉前后空格，避免输入错误）。
    func updateUploadEndpoint(_ endpoint: String) {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: AppConfig.uploadEndpointKey)
    }
    
    /// 从 upload 地址推导出 /health 检查地址。
    func healthCheckURL(from uploadEndpoint: String) -> URL? {
        let trimmed = uploadEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        
        components.path = "/health"
        components.query = nil
        components.fragment = nil
        return components.url
    }
    
    /// 测试 Mac 服务是否可达（GET /health）。
    func testServerConnection(endpoint: String, completion: @escaping (Bool, String) -> Void) {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async {
                completion(false, "请先填写服务地址")
            }
            return
        }
        
        if trimmed.contains("198.18.") {
            DispatchQueue.main.async {
                completion(false, "198.18.x 是 VPN/代理地址，iPad 无法访问，请改用 Mac 局域网 IP")
            }
            return
        }
        
        guard let url = healthCheckURL(from: trimmed) else {
            DispatchQueue.main.async {
                completion(false, "地址格式不正确，示例：http://192.168.x.x:8765/upload")
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        
        print("【MathCanvas】测试连接：\(url.absoluteString)")
        
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                let message = Self.friendlyNetworkError(error)
                print("【MathCanvas】测试失败：\(message)")
                DispatchQueue.main.async { completion(false, message) }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(false, "未收到 HTTP 响应") }
                return
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                print("【MathCanvas】测试成功：status=\(httpResponse.statusCode)")
                DispatchQueue.main.async { completion(true, "连接正常，Mac 服务可用 ✓") }
            } else {
                DispatchQueue.main.async {
                    completion(false, "服务返回 HTTP \(httpResponse.statusCode)")
                }
            }
        }.resume()
    }
    
    /// 把 URLError 转成可操作的提示文案。
    static func friendlyNetworkError(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        
        switch urlError.code {
        case .timedOut:
            return "连接超时：确认 Mac 服务已启动，且 iPad 与 Mac 在同一 Wi-Fi"
        case .cannotConnectToHost:
            return "无法连接：Mac 服务未运行，或地址/端口填错"
        case .cannotFindHost:
            return "找不到主机：IP 可能填错（不要用 198.18.x）"
        case .notConnectedToInternet:
            return "网络不可用：请检查 Wi-Fi 连接"
        case .networkConnectionLost:
            return "连接中断：请重试"
        default:
            let description = urlError.localizedDescription.lowercased()
            if description.contains("local network") || description.contains("本地网络") {
                return "请前往「设置 → MathCanvas」允许本地网络访问"
            }
            return urlError.localizedDescription
        }
    }
    
    // MARK: 显示 PencilKit 工具选择器
    /// 调出官方的工具面板（笔、橡皮擦、尺子、颜色选择器等）。
    /// 必须在 canvasView 已经被加入窗口（有 window）之后调用，否则不会显示。
    func showToolPicker() {
        // iOS 17+ 用实例属性 toolPicker，不再有 PKToolPicker.shared
        // 关键：让 canvasView 观察 toolPicker 的工具变化。
        // 不加这一行时，可能出现“面板切到了橡皮擦，但画布仍然用钢笔”的现象。
        if !didAddToolPickerObserver {
            toolPicker.addObserver(canvasView)
            didAddToolPickerObserver = true
        }
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        
        // 主动让画布成为第一响应者（很重要！只有成为第一响应者，工具面板才会出现）
        canvasView.becomeFirstResponder()
        
        // 兜底：如果 updateUIView 没在合适时机触发，这里再次确保无限画布被初始化。
        configureInfiniteCanvasIfNeeded()
    }
    
    // MARK: 无边记风格无限画布
    /// 把 PKCanvasView 配置成「可无限平移 + 可缩放」的工作区体验。
    /// 说明：
    /// - 通过超大 contentSize 模拟无限画布
    /// - 初始定位到工作区中心，便于四周继续拓展
    /// - 开启 zoom，让你像无边记一样放大/缩小查看细节
    func configureInfiniteCanvasIfNeeded() {
        guard !didConfigureInfiniteCanvas else { return }
        guard canvasView.bounds.width > 0, canvasView.bounds.height > 0 else { return }
        
        canvasView.contentSize = workspaceSize
        canvasView.isScrollEnabled = true
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.minimumZoomScale = 0.2
        canvasView.maximumZoomScale = 6.0
        canvasView.zoomScale = 1.0
        
        canvasView.bouncesZoom = true
        canvasView.alwaysBounceHorizontal = true
        canvasView.alwaysBounceVertical = true
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.showsVerticalScrollIndicator = false
        
        // 初始显示在大画布的中心区域，避免一上来就贴着左上角边缘。
        let centeredOffset = CGPoint(
            x: (workspaceSize.width - canvasView.bounds.width) / 2,
            y: (workspaceSize.height - canvasView.bounds.height) / 2
        )
        canvasView.setContentOffset(centeredOffset, animated: false)
        
        didConfigureInfiniteCanvas = true
    }
}

// MARK: - PencilCanvasView
/// 这是一个「桥接组件」（UIViewRepresentable），负责把 UIKit 的 PKCanvasView 嵌入到 SwiftUI 界面里。
/// SwiftUI 自己没有 PencilKit 组件，所以我们必须用这种方式包装。
struct PencilCanvasView: UIViewRepresentable {
    
    /// 通过 @ObservedObject 观察 CanvasManager，
    /// 当 manager 里的 canvasView 发生变化时（其实我们基本不改它），界面能保持同步。
    @ObservedObject var manager: CanvasManager
    
    /// 创建真正的 PKCanvasView（只会调用一次）
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = manager.canvasView
        
        // 可选：设置 delegate，用于监听笔迹变化（画完一笔、撤销、重做等）
        // 我们先留空，Coordinator 也先不写具体逻辑，后面有需要再加。
        canvas.delegate = context.coordinator
        
        return canvas
    }
    
    /// 当 SwiftUI 界面需要刷新时会调用这里。
    /// 我们这个 App 里画布基本不需要外部驱动刷新，所以留空即可。
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // 在真正拿到尺寸后，初始化「无限画布」参数。
        manager.configureInfiniteCanvasIfNeeded()
    }
    
    /// 创建协调器（Coordinator）。
    /// Coordinator 是 UIKit 和 SwiftUI 之间的「中间人」，常用来实现各种 Delegate。
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    // 内部的协调器类
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        // 目前我们不需要实现任何代理方法。
        // 如果以后想「每画完一笔就自动保存」、或「检测到大量笔迹就提示」，可以在这里加：
        //
        // func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        //     // 在这里做点什么
        // }
    }
}

// MARK: - ContentView
/// 整个 App 的主界面。
/// 采用 ZStack 把「全屏画布」和「悬浮按钮」叠在一起，达到沉浸式手写体验。
struct ContentView: View {
    
    /// 持有画布管理器，使用 @StateObject 保证整个 View 生命周期内只创建一次。
    @StateObject private var canvasManager = CanvasManager()
    
    /// 发送成功后的简单提示状态
    @State private var showSentConfirmation = false
    @State private var sentConfirmationMessage = ""
    @State private var sentConfirmationIsError = false
    
    /// 服务地址设置弹窗
    @State private var showEndpointSheet = false
    @State private var endpointDraft = ""
    
    var body: some View {
        ZStack {
            // 1. 全屏 PencilKit 画布
            //    .ignoresSafeArea() 让它真正铺满整个屏幕（包括刘海、home indicator 区域），
            //    手写时不会有白边或被安全区域裁掉的问题。
            PencilCanvasView(manager: canvasManager)
                .ignoresSafeArea()
            
            // 2. 右下角悬浮圆按钮（更接近无边记风格）
            //    视觉目标：
            //    - 操作层更轻，不抢手写内容
            //    - 毛玻璃圆按钮 + 柔和阴影，保持现代感
            //    - 放在右下角，便于单手点按
            VStack {
                Spacer()
                
                HStack {
                    Spacer()
                    
                    VStack(spacing: 14) {
                        // —— 设置按钮（给分享版本非常重要）——
                        Button {
                            endpointDraft = canvasManager.currentUploadEndpoint()
                            showEndpointSheet = true
                        } label: {
                            FreeformFloatingButton(
                                title: "服务",
                                systemImage: "network",
                                tint: .indigo
                            )
                        }
                        
                        // —— 发送按钮（主按钮）——
                        Button {
                            if let image = canvasManager.exportAsImage() {
                                canvasManager.sendImageToServer(image: image) { success, message in
                                    sentConfirmationMessage = message
                                    sentConfirmationIsError = !success
                                    withAnimation(.spring) {
                                        showSentConfirmation = true
                                    }
                                    
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                        withAnimation {
                                            showSentConfirmation = false
                                        }
                                    }
                                }
                            }
                        } label: {
                            FreeformFloatingButton(
                                title: "发送",
                                systemImage: "paperplane.fill",
                                tint: .blue
                            )
                        }
                        
                        // —— 清空按钮（次按钮）——
                        Button {
                            canvasManager.clearCanvas()
                        } label: {
                            FreeformFloatingButton(
                                title: "清空",
                                systemImage: "trash.fill",
                                tint: .red
                            )
                        }
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 36)
                }
            }
            
            // 3. 发送成功后的顶部提示条（半透明）
            //    顶部居中轻提示，避免遮挡右下角按钮。
            if showSentConfirmation {
                VStack {
                    Text(sentConfirmationMessage)
                        .font(.callout.bold())
                        .foregroundStyle(sentConfirmationIsError ? .red : .primary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                        .shadow(radius: 8)
                    
                    Spacer()
                }
                .padding(.top, 88)   // 88pt 足够让提示条出现在按钮卡片下方
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 界面出现后，延迟一点点显示工具选择器
        // 为什么延迟？因为第一次 makeUIView 时，canvasView 可能还没被加到 window 上，
        // 必须等它真正出现在屏幕上，becomeFirstResponder() 才会生效。
        .onAppear {
            endpointDraft = canvasManager.currentUploadEndpoint()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                canvasManager.configureInfiniteCanvasIfNeeded()
                canvasManager.showToolPicker()
            }
        }
        .sheet(isPresented: $showEndpointSheet) {
            ServerEndpointSheet(
                endpointDraft: $endpointDraft,
                currentEndpoint: canvasManager.currentUploadEndpoint(),
                onSave: {
                    canvasManager.updateUploadEndpoint(endpointDraft)
                    showEndpointSheet = false
                },
                onReset: {
                    endpointDraft = AppConfig.defaultUploadEndpoint
                },
                onTestConnection: { endpoint, completion in
                    canvasManager.testServerConnection(endpoint: endpoint, completion: completion)
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - 无边记风格悬浮按钮
/// 轻量级的毛玻璃圆形按钮，风格更接近 Freeform（无边记）。
private struct FreeformFloatingButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 54, height: 54)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle().stroke(.white.opacity(0.55), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 服务地址设置弹窗
private struct ServerEndpointSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var endpointDraft: String
    let currentEndpoint: String
    let onSave: () -> Void
    let onReset: () -> Void
    let onTestConnection: (String, @escaping (Bool, String) -> Void) -> Void
    
    @State private var isTestingConnection = false
    @State private var testResultMessage: String?
    @State private var testResultSuccess: Bool?
    
    var body: some View {
        NavigationStack {
            Form {
                Section("当前地址") {
                    Text(currentEndpoint)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                
                Section("修改服务地址") {
                    TextField("http://192.168.x.x:8765/upload", text: $endpointDraft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: endpointDraft) { _, _ in
                            testResultMessage = nil
                            testResultSuccess = nil
                        }
                    
                    Button("恢复默认地址") {
                        onReset()
                        testResultMessage = nil
                        testResultSuccess = nil
                    }
                }
                
                Section("连接测试") {
                    Button {
                        testResultMessage = nil
                        testResultSuccess = nil
                        isTestingConnection = true
                        onTestConnection(endpointDraft) { success, message in
                            isTestingConnection = false
                            testResultSuccess = success
                            testResultMessage = message
                        }
                    } label: {
                        HStack {
                            Text("测试连接")
                            Spacer()
                            if isTestingConnection {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingConnection)
                    
                    if let testResultMessage {
                        Label {
                            Text(testResultMessage)
                        } icon: {
                            Image(systemName: testResultSuccess == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                        }
                        .foregroundStyle(testResultSuccess == true ? .green : .red)
                        .font(.footnote)
                    }
                    
                    Text("会向 Mac 的 /health 接口发送请求，确认服务是否在线。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Section("说明") {
                    Text("你的 iPad 和 Mac 必须在同一个局域网。")
                    Text("通常只需要改 IP，端口保持 8765，路径保持 /upload。")
                    Text("不要用 198.18.x 地址——那是 Mac 上 VPN/代理的虚拟网卡，iPad 访问不到。")
                }
            }
            .navigationTitle("服务设置")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        endpointDraft = currentEndpoint
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - 预览
#Preview {
    ContentView()
}
