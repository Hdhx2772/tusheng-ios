import SwiftUI
import UIKit

// MARK: - AI 聊天详情页（由会话列表 push 进入，不再自带 NavigationView）
struct AIChatView: View {
    @ObservedObject var store: ChatStore
    @StateObject private var viewModel: AIChatViewModel
    @FocusState private var isInputFocused: Bool

    // 是否在底部附近：用户在底部时才自动跟随滚动，上翻看历史时不打扰
    @State private var isNearBottom = true
    private let bottomAnchorID = "bottom_anchor"

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
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        // 底部锚点：用于判断当前滚动位置
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ScrollOffsetKey.self,
                                        value: geo.frame(in: .named("chatScroll")).maxY
                                    )
                                }
                            )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .coordinateSpace(name: "chatScroll")
                .onPreferenceChange(ScrollOffsetKey.self) { maxY in
                    // 内容底部 maxY：在底部时 ≈ ScrollView 可视高度；
                    // 上翻时 maxY 变大（内容底部移出可视区）
                    let bottom = outer.size.height
                    isNearBottom = maxY <= bottom + 120
                }
                .onChange(of: messages.count) { _ in
                    // 用户刚发出消息 → 强制滚到底部看到自己的消息
                    // AI 新增占位气泡 → 仅当已在底部时才跟随，不打扰上翻的用户
                    if messages.last?.role == .user {
                        scrollToBottom(proxy)
                    } else if isNearBottom {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: messages.last?.content) { _ in
                    if messages.last?.isStreaming == true && isNearBottom {
                        scrollToBottom(proxy)
                    }
                }
                .background(Color(.systemGroupedBackground))
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
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

            // 气泡 + 复制按钮，整体按角色对齐
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                bubble
                if !message.content.isEmpty {
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

// MARK: - 滚动位置检测（判断用户是否在底部附近）
struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
