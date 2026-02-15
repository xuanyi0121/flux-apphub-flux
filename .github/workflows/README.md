# GitHub Actions iOS 构建说明

## 配置 API URL

### 方法 1: 通过 GitHub Secrets（推荐）

1. 进入仓库 **Settings → Secrets and variables → Actions**
2. 点击 **"New repository secret"**
3. 添加以下 Secret:
   - **Name**: `API_BASE_URL`
   - **Value**: 您的 API 地址，例如 `https://your-panel.com/api/v1`
4. 保存后，构建时会自动使用该 URL

### 方法 2: 通过手动输入

在运行工作流时，可以在 **"API Base URL"** 输入框中直接输入 API 地址。

### 方法 3: 使用默认值

如果不配置，将使用代码中的默认值 `https://node.quicklian.com/api/v1`

**注意**: API URL 会在编译时注入到应用中，构建后无法更改。如果需要更改，需要重新构建。

## 工作流文件

### 1. `build-ios.yml` - 无签名构建（推荐用于测试）

**用途**: 构建 iOS 应用，不进行代码签名，生成 `.app` 和 `.xcarchive` 文件

**触发方式**:
- 手动触发 (workflow_dispatch)
- 推送到 main/master 分支
- Pull Request

**输出**:
- `Runner.app` - 未签名的应用包
- `Runner.xcarchive` - Xcode Archive 文件

**使用方法**:
1. 在 GitHub 仓库中，进入 Actions 标签
2. 选择 "Build iOS" 工作流
3. 点击 "Run workflow"
4. 选择构建模式（release/debug）
5. 等待构建完成
6. 在 Artifacts 中下载构建产物

### 2. `build-ios-signed.yml` - 签名构建（用于发布）

**用途**: 构建并签名 iOS 应用，生成可安装的 `.ipa` 文件

**触发方式**: 仅手动触发 (workflow_dispatch)

**需要配置的 Secrets**:
- `IOS_BUILD_CERTIFICATE_BASE64` - 开发者证书（.p12 文件，base64 编码）
- `IOS_P12_PASSWORD` - P12 证书密码
- `IOS_KEYCHAIN_PASSWORD` - Keychain 密码
- `IOS_PROVISIONING_PROFILE_BASE64` - 配置文件（.mobileprovision，base64 编码）
- `IOS_CODE_SIGN_IDENTITY` - 代码签名标识（如：Apple Development）
- `IOS_PROVISIONING_PROFILE_SPECIFIER` - 配置文件名称

**输出**:
- `flux-ios-*.ipa` - 已签名的 IPA 文件

**配置步骤**:

1. **导出证书和配置文件**:
   ```bash
   # 在 macOS 上执行
   # 导出证书为 P12
   security find-identity -v -p codesigning
   security export -k ~/Library/Keychains/login.keychain-db -t identities -f pkcs12 -o certificate.p12
   
   # 转换为 base64
   base64 -i certificate.p12 -o certificate_base64.txt
   
   # 配置文件转换为 base64
   base64 -i profile.mobileprovision -o profile_base64.txt
   ```

2. **在 GitHub 仓库中配置 Secrets**:
   - Settings → Secrets and variables → Actions
   - 添加上述所有 Secrets

3. **修改 ExportOptions.plist**:
   - 编辑 `ios/ExportOptions.plist`
   - 设置正确的 `teamID` 和 `method`

4. **运行工作流**:
   - 在 Actions 中选择 "Build iOS (Signed IPA)"
   - 点击 "Run workflow"

## 注意事项

1. **无签名构建**: 生成的 `.app` 文件无法直接安装到设备，需要签名
2. **签名构建**: 需要有效的 Apple 开发者账号和证书
3. **构建时间**: 首次构建可能需要 10-20 分钟
4. **CocoaPods**: 会自动安装依赖
5. **Flutter 版本**: 当前使用 3.27.1，支持 Dart SDK >=3.5.0，可在 workflow 文件中修改

## 常见问题

**Q: 构建失败，提示证书错误**
A: 检查 Secrets 配置是否正确，证书是否过期

**Q: 如何修改 Flutter 版本**
A: 编辑 workflow 文件中的 `flutter-version` 参数

**Q: 如何构建特定版本**
A: 使用 `workflow_dispatch` 手动触发，可以指定构建模式
