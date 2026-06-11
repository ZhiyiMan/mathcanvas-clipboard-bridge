//
//  AppConfig.swift
//  MathCanvas
//
//  统一管理应用级配置，便于后续维护和分享给朋友。
//

import Foundation

enum AppConfig {
    /// 首次使用时的占位值（空字符串）。
    /// 目的：强制新用户在第一次打开 App 时必须配置 Mac 服务的真实地址，
    /// 避免把“上一个用户的 192.168.x.x”当成默认值导致发送失败。
    /// 保存后会写入 UserDefaults，之后一直使用用户自己填的地址。
    static let defaultUploadEndpoint = ""
    
    /// UserDefaults 里保存服务地址的 key。
    static let uploadEndpointKey = "mathcanvas.uploadEndpoint"
    
    /// 给设置页 TextField 用的示例占位文本（仅用于视觉提示，不作为真实默认值保存）。
    static let endpointPlaceholder = "http://192.168.x.x:8765/upload"
}
