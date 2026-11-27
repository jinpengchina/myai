import SwiftUI
import UIKit

/// Presents conversations over the chat without replacing its draft or navigation state.
struct ThreadsDrawer<Drawer: View>: ViewModifier {
    @Binding var isOpen: Bool
    var enabled: Bool
    @ViewBuilder var drawer: () -> Drawer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var draggingHorizontally = false
    @State private var sideways: [CGRect] = []

    func body(content: Content) -> some View {
        content
            .environment(\.coveredByDrawer, isOpen)
            .accessibilityHidden(isOpen)
            .onPreferenceChange(SidewaysScrollAreas.self) { sideways = $0 }
            .overlay {
                if isOpen {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            closeButton
                            drawer()
                                .environment(\.inThreadsDrawer, true)
                                .environment(\.drawerSliding, draggingHorizontally)
                                .environment(\.colorScheme, .dark)
                                .foregroundStyle(.white)
                                .frame(width: min(360, max(1, geometry.size.width - 48)))
                                .frame(maxHeight: .infinity)
                                .background(Color.black)
                                .accessibilityAction(.escape) { setOpen(false) }
                                .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                        }
                    }
                    .transition(.opacity)
                }
            }
            .simultaneousGesture(swipe, including: (enabled || isOpen) ? .all : .subviews)
            .onChange(of: isOpen) { _, open in
                if open {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : ThreadsDrawerMotion.settle, value: isOpen)
    }

    private var closeButton: some View {
        Button {
            setOpen(false)
        } label: {
            Color.black.opacity(0.56)
                .ignoresSafeArea()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Conversations")
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .updating($draggingHorizontally) { value, state, _ in
                state = isOpen && value.translation.width < -abs(value.translation.height)
            }
            .onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) else { return }
                if isOpen && dx < -64 {
                    setOpen(false)
                } else if enabled && !isOpen && dx > 64 && value.startLocation.x < 28
                            && !sideways.contains(where: { $0.contains(value.startLocation) }) {
                    setOpen(true)
                }
            }
    }

    private func setOpen(_ value: Bool) {
        isOpen = value
    }
}

enum ThreadsDrawerMotion {
    static let settle = Animation.easeInOut(duration: 0.23)
}

extension EnvironmentValues {
    @Entry var coveredByDrawer = false
    @Entry var inThreadsDrawer = false
    @Entry var drawerSliding = false
}

struct SidewaysScrollAreas: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    func scrollsSideways(_ on: Bool = true) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: SidewaysScrollAreas.self, value: on ? [geometry.frame(in: .global)] : [])
            }
        }
    }

    func threadsDrawer<Drawer: View>(isOpen: Binding<Bool>, enabled: Bool, @ViewBuilder drawer: @escaping () -> Drawer) -> some View {
        modifier(ThreadsDrawer(isOpen: isOpen, enabled: enabled, drawer: drawer))
    }
}
