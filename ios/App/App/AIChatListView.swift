import SwiftUI

// MARK: - AI 对话入口：会话历史列表（独立界面的根视图）
struct AIChatListView: View {
    @StateObject private var store: ChatStore
    @Environment(\.presentationMode) private var presentationMode
    // 用于“新建聊天”后的程序化跳转
    @State private var newSessionId: UUID?
    // 长按删除：待删除的会话与确认弹窗开关
    @State private var sessionToDelete: ChatSession?
    @State private var showDeleteConfirm = false

    init(deviceCode: String) {
        _store = StateObject(wrappedValue: ChatStore(deviceCode: deviceCode))
    }

    var body: some View {
        NavigationView {
            Group {
                if store.sessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("AI 对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let s = store.createSession()
                        newSessionId = s.id
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新建聊天")
                }
            }
            .alert("提示", isPresented: $store.showAuthAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(store.authMessage)
            }
            .alert("删除对话", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) { sessionToDelete = nil }
                Button("删除", role: .destructive) {
                    if let s = sessionToDelete {
                        store.deleteSession(s.id)
                    }
                    sessionToDelete = nil
                }
            } message: {
                Text("确定要删除「\(sessionToDelete?.title ?? "")」吗？此操作不可撤销。")
            }
            .task {
                await store.checkAuthOnOpen()
            }
            .background(
                // 隐藏的编程式跳转链接，承载“新建聊天”进入的页面
                NavigationLink(
                    destination: newChatDestination,
                    isActive: Binding(
                        get: { newSessionId != nil },
                        set: { active in if !active { newSessionId = nil } }
                    )
                ) { EmptyView() }
                .hidden()
            )
        }
        .navigationViewStyle(.stack)
    }

    // 新建会话的目标页
    @ViewBuilder
    private var newChatDestination: some View {
        if let sid = newSessionId {
            AIChatView(store: store, sessionId: sid)
        } else {
            EmptyView()
        }
    }

    // MARK: - 历史会话列表
    private var sessionList: some View {
        List {
            Section {
                Button {
                    let s = store.createSession()
                    newSessionId = s.id
                } label: {
                    Label("新建聊天", systemImage: "square.and.pencil")
                        .foregroundColor(.blue)
                }
            }
            Section("历史记录") {
                ForEach(store.sortedSessions) { session in
                    NavigationLink {
                        AIChatView(store: store, sessionId: session.id)
                    } label: {
                        sessionRow(session)
                    }
                }
                .onDelete(perform: deleteSessions)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func deleteSessions(_ offsets: IndexSet) {
        let sorted = store.sortedSessions
        for index in offsets {
            store.deleteSession(sorted[index].id)
        }
    }

    private func sessionRow(_ s: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.title)
                .font(.headline)
                .lineLimit(1)
            Text(previewText(s))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(timeText(s.updatedAt))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.5) {
            sessionToDelete = s
            showDeleteConfirm = true
        }
    }

    private func previewText(_ s: ChatSession) -> String {
        guard let last = s.messages.last else { return "暂无消息" }
        let p = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? "暂无消息" : p
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "今天 HH:mm"
        } else {
            f.dateFormat = "MM月dd日 HH:mm"
        }
        return f.string(from: date)
    }

    // MARK: - 空状态
    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 54))
                .foregroundColor(.secondary)
            Text("还没有对话")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("点击下方按钮，开始与 AI 对话")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button {
                let s = store.createSession()
                newSessionId = s.id
            } label: {
                Label("开始新对话", systemImage: "plus.message.fill")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.blue))
                    .foregroundColor(.white)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
