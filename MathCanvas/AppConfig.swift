//
//  AppConfig.swift
//  MathCanvas
//
//  统一管理应用级配置，便于后续维护和分享给朋友。
//

import Foundation

enum AppConfig {
    /// 第一次安装时使用的默认服务地址。
    /// 你可以改成自己常用的 IP，也可以在 App 里随时改。
    static let defaultUploadEndpoint = "http://192.168.2.101:8765/upload"
    
    /// UserDefaults 里保存服务地址的 key。
    static let uploadEndpointKey = "mathcanvas.uploadEndpoint"
}
