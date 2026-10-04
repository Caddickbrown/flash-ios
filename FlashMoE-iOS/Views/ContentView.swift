/*
 * ContentView.swift — Root navigation
 *
 * Model library until a model is loaded, chat once it is. The switch is a
 * cross-fade rather than a push, since there is nothing to go "back" to —
 * unloading the model is what returns you to the library.
 */

import SwiftUI

struct ContentView: View {
    @Environment(FlashMoEEngine.self) private var engine

    var body: some View {
        ZStack {
            FM.ground.ignoresSafeArea()

            switch engine.state {
            case .idle, .loading, .error:
                ModelListView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.02)),
                        removal: .opacity.combined(with: .scale(scale: 0.98))
                    ))
            case .ready, .generating:
                ChatView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity.combined(with: .scale(scale: 1.02))
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: engine.state)
        .preferredColorScheme(.dark)
    }
}
