# 可选朗读服务

「设置 → 朗读 → 朗读引擎」及阅读页的朗读设置可选系统、Edge、Azure、豆包、CosyVoice 和原有自定义接口。设置页的「试听」与正文使用同一请求实现。新选项不会改变既有引擎或配置。

## Azure

在 Azure 创建 Speech 资源，填资源区域（例如 `eastasia`）和该资源的 Speech Key，选择/填写音色 ID，先点试听。内置快捷音色为晓晓、云希、云扬；实际可用音色以区域和账户为准。

通过 [Azure 官方 REST 接口](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-text-to-speech) 发送 SSML，返回 MP3；语速、音调使用现有朗读参数。当前支持全球 Azure 的区域域名，不包含中国区独立云或自定义部署端点。免费额度、权限和并发限制以账户为准。

## 豆包

使用新版豆包语音控制台的 **语音 API Key**，不是方舟文本大模型 API Key，也不是旧版 App ID/Access Token。填写资源 ID（默认 `seed-tts-2.0`）和对应已授权的音色 ID；为避免预设未授权音色，首次需自行填写音色。

按[官方 V3 HTTP/SSE 协议](https://docs.volcengine.com/docs/doubao-voice/http-chunked-sse-unidirectional-streaming-v3?lang=zh) 请求，拼接 Base64 MP3 音频帧，收到成功结束码后才播放和缓存。错误帧、格式错误或缺少结束帧不会保存部分音频。当前沿用播放器逐块预取，收齐一个块后播放，不是边收到字节边播放。支持语速，不额外改变音调，音量由播放器控制。调用可能消耗试用额度或产生费用。

## CosyVoice 自部署

手机连接服务器，不在手机中运行模型。可使用支持 WAV 的 OpenAI `/v1/audio/speech` 网关，也可运行项目附带的 `Tools/cosyvoice-gateway.py`。

先按 [CosyVoice 官方说明](https://github.com/QwenAudio/CosyVoice) 准备模型、依赖及参考音频，使用其 Python 环境，从 **CosyVoice 仓库目录**运行，例如 CosyVoice 3：

```bash
export COSYVOICE_API_KEY='自行设置的网关密钥'
python /path/to/NovelReader/Tools/cosyvoice-gateway.py \
  --model-dir pretrained_models/Fun-CosyVoice3-0.5B \
  --prompt-wav /path/to/reference.wav \
  --prompt-text 'You are a helpful assistant.<|endofprompt|>参考音频的准确文字内容' \
  --host 0.0.0.0 --port 8880
```

参考音频和文字在服务器固定，客户端不能上传或改变；当前网关只提供一个命名音色（默认 `default`，用 `--voice` 修改）。CosyVoice 2 的 prompt text 使用原始参考文字，不加 CosyVoice 3 的前缀。网关依照[官方 zero-shot 推理示例](https://github.com/QwenAudio/CosyVoice/blob/main/example.py) 调用，返回模型实际采样率的单声道 16 位 WAV。

手机配置：

- 网关地址：`http://电脑局域网IP:8880/v1`（`127.0.0.1` 指手机自身）。
- 模型：`cosyvoice`，音色：`default`。
- API Key：上面配置的网关密钥；服务器未配置密钥时才留空。
- 手机与服务器网络互通，并允许 iOS 的本地网络访问。网关默认只监听回环地址，供手机使用时才指定局域网监听地址；如需公网访问，应自行配置 HTTPS 和访问控制。

网关支持 0.5–2 倍语速、单次 1–4000 字；模型推理串行执行，音调不单独调整。其 Python 环境需要已有 CosyVoice 依赖，脚本不自动下载模型。服务器运行时间、硬件和电力不是免费云服务。

## 存储与校验

三个服务的配置、音色和密钥互相独立。密钥存于本机 Keychain，普通 JSON 配置会剥离所有服务密钥；当前跨设备同步不包含这些 TTS 配置。音频缓存按引擎、音色、区域/资源/端点及语速区分，密钥不出现在缓存标识中。鉴权/配置错误会停止重试；限流和网络错误沿用恢复策略。

新增 9 项 Swift 测试验证旧配置迁移、请求鉴权与正文、音频帧拼接和结束状态、错误响应、缓存身份及密钥剥离；4 项网关测试含真实本机 HTTP 鉴权与模拟 WAV 返回。未使用真实 Azure/豆包账户凭据，也未下载和运行 CosyVoice 模型；iOS 构建和真机试听尚未验证。
