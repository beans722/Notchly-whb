import SwiftUI

struct FocusPetView: View {
    let pet: FocusPet
    let size: CGFloat
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false

    var body: some View {
        Image(pet.imageName)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(width: size, height: size)
            .offset(y: isActive && moving && !reduceMotion ? -2.5 : 0)
            .rotationEffect(.degrees(pet == .calf && moving && isActive && !reduceMotion ? -4 : 0))
            .accessibilityLabel(pet.title)
            .onAppear(perform: updateAnimation)
            .onChange(of: isActive) { _, _ in updateAnimation() }
            .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        moving = false
        guard isActive, !reduceMotion else { return }
        withAnimation(
            .easeInOut(duration: pet == .jumpingBean ? 0.42 : 0.68)
                .repeatForever(autoreverses: true)
        ) {
            moving = true
        }
    }
}
