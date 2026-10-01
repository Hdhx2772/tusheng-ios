import SwiftUI
import UIKit

// MARK: - AI 聊天详情页（由会话列表 push 进入，不再自带 NavigationView）
struct AIChatView: View {
    @ObservedObject var store: ChatStore
    @StateObject private var viewModel: AIChatViewModel
    @FocusState private var isInputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    // 用户是否手动上翻过（看历史）：一旦上翻就停止自动跟随，直到用户发新消息或点"回到底部"
    @State private var userScrolledUp = false
    @State private var scrollProxy: ScrollViewProxy?
    // 滚动节流：流式增量到达时最多每 0.3s 跟随一次，避免滚动动画风暴导致卡顿
    @State private var lastAutoScrollTime = Date.distantPast

    private let sessionId: UUID

    init(store: ChatStore, sessionId: UUID) {
        self.store = store
        self.sessionId = sessionId
        _viewModel = StateObject(wrappedValue: AIChatViewModel(store: store, sessionId: sessionId))
    }

    private var session: ChatSession? { store.session(sessionId) }
    private var messages: [ChatMessage] { session?.messages ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            inputBar
        }
        .overlay(alignment: .bottomTrailing) {
            // 用户上翻看历史时显示"回到底部"按钮
            if userScrolledUp {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) {
                        userScrolledUp = false
                        if let proxy = scrollProxy {
                            scrollToBottom(proxy)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down")
                        Text("回到底部")
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(.systemBackground)))
                    .overlay(Capsule().stroke(Color(.systemGray4), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle(session?.title ?? "对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        viewModel.clearChat()
                    } label: {
                        Label("清空当前对话", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("提示", isPresented: $store.showAuthAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(store.authMessage)
        }
        .onChange(of: scenePhase) { phase in
            // 切后台再回来：如果生成被系统断开，自动恢复重连
            if phase == .active {
                viewModel.resumeIfNeeded()
            }
        }
    }

    // MARK: - 消息列表
    private var messageList: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(messages) { message in
                                MessageBubble(message: message) {
                                    viewModel.retryGeneration(messageId: message.id)
                                }
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                // 直接监听用户拖动手势：用户上翻（手指向下滑）→ 停止自动跟随
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            // 手指向下滑（translation.height > 0）= 查看上方历史 → 停止跟随
                            if value.translation.height > 8 {
                                userScrolledUp = true
                            }
                        }
                )
                .onChange(of: messages.count) { _ in
                    // 用户刚发出消息 → 强制滚到底部并恢复跟随
                    if messages.last?.role == .user {
                        userScrolledUp = false
                        scrollToBottom(proxy)
                    } else if !userScrolledUp {
                        // AI 新增消息 → 用户在底部才跟随
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: messages.last?.content) { _ in
                    // 流式生成中：仅当用户没有手动上翻时才跟随到底部；
                    // 节流控制跟随频率，避免每个 delta 都滚动动画导致卡顿
                    if messages.last?.isStreaming == true && !userScrolledUp {
                        let now = Date()
                        guard now.timeIntervalSince(lastAutoScrollTime) > 0.3 else { return }
                        lastAutoScrollTime = now
                        scrollToBottom(proxy)
                    }
                }
                .background(Color(.systemGroupedBackground))
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        // 无动画直接定位：流式期间频繁跟随，动画叠加反而更卡
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    // MARK: - 空状态
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 46))
                .foregroundColor(.secondary)
            Text("开始与 AI 对话")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("输入任何问题，AI 将为你解答")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // MARK: - 输入栏
    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("输入消息...", text: $viewModel.inputText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(.systemGray6))
                    )
                    .focused($isInputFocused)
                    .lineLimit(5)

                if viewModel.isLoading {
                    Button {
                        viewModel.stopGeneration()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.red)
                    }
                } else {
                    Button {
                        Task {
                            await viewModel.sendMessage()
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(canSend ? .blue : .gray)
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
    }

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 消息气泡
struct MessageBubble: View {
    let message: ChatMessage
    var onRetry: (() -> Void)?
    @State private var copied = false

    private let bubbleMaxWidth = UIScreen.main.bounds.width * 0.78

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // 用户消息：左侧弹性空间，把气泡推到右边
            if message.role == .user {
                Spacer(minLength: 32)
            }
            // AI 消息：头像在最左
            if message.role == .assistant {
                avatar
            }

            // 气泡 + 复制/重试按钮，整体按角色对齐
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                bubble
                if message.isInterrupted {
                    retryButton
                } else if !message.content.isEmpty {
                    copyButton
                }
            }
            .frame(maxWidth: bubbleMaxWidth, alignment: message.role == .user ? .trailing : .leading)

            // AI 消息：右侧弹性空间，把气泡留在左边
            if message.role == .assistant {
                Spacer(minLength: 32)
            }
        }
    }

    // MARK: 中断重试按钮（网络中断内容已保存时显示）
    private var retryButton: some View {
        HStack(spacing: 6) {
            Button {
                onRetry?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("重新生成")
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.blue.opacity(0.12)))
                .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            if !message.content.isEmpty {
                copyButton
            }
        }
    }

    // MARK: 气泡本体
    @ViewBuilder
    private var bubble: some View {
        if message.content.isEmpty && message.isStreaming {
            // 思考中：转圈 + 提示
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("思考中…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemGray6))
            )
        } else {
            Text(message.content)
                .font(.body)
                .foregroundColor(message.role == .user ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(message.role == .user ? Color.blue : Color(.systemGray6))
                )
                .textSelection(.enabled)
        }
    }

    // MARK: 复制按钮（每个气泡都有）
    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = message.content
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 11))
                if copied {
                    Text("已复制")
                        .font(.system(size: 11))
                }
            }
            .foregroundColor(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: AI 头像
    private var avatar: some View {
        Circle()
            .fill(LinearGradient(
                colors: [.purple, .blue],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            )
    }
}

// MARK: - 滚动策略说明
// v18 起不再使用 GeometryReader/preference 检测滚动位置：
// SwiftUI ScrollView 滚动时不会重新布局内容，preference 拿到的 frame
// 在滚动期间不更新，导致"是否在底部"永远误判为 true，AI 内容一更新
// 就把用户拉回底部。v18 改为 DragGesture 手势检测 + "回到底部"按钮：
//   1. 用户上翻（手指向下滑）→ userScrolledUp=true，停止自动跟随
//   2. 生成中新内容到达 → 仅当 !userScrolledUp 时才滚到底部
//   3. 用户发新消息 → 强制滚底并恢复跟随
//   4. 上翻时显示"回到底部"浮动按钮，点击恢复
