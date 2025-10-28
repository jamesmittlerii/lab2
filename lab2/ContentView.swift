/**
 
 * __Partner Lab 3__
 * Jim Mittler
 * 20 October 2025
 
 
 We've updated our Game to use MVVM architecture
 
 all the game logic is moved to the GameModel class
 
 ContentView contains the UI logic and the code to support showing the global leaderboard
 
 The game connects to Game Center to keep track of personal best and show a global leaderboard of all the players
 
 We show a 4x6 grid of randomly shuffled tile pairs.
 If you match two tiles they remain face up until you complete the game.
 We show some confetti when you win.
 
 _Italic text__
 __Bold text__
 ~~Strikethrough text~~
 
 */

import Combine
import GameKit
import SwiftUI

/* this is our structure for the tiled card in the UI */
struct TiledCard: View {
    let card: Card
    let isFaceUp: Bool
    let isMatchWiggling: Bool
    let isWinWiggling: Bool
    let onTap: () -> Void

    // rotation angle is for wiggle
    @State private var rotationAngle: Angle = .zero
    @State private var flipRotation: Double = 0

    // Animation constants
    private let flipDuration: Double = 0.4
    private let wiggleAngle: Double = 4
    private let wiggleStepDuration: Double = 0.125

    var body: some View {
        ZStack {
            // FRONT face
            Group {
                RoundedRectangle(cornerRadius: 10)
                    .foregroundColor(.white)
                RoundedRectangle(cornerRadius: 10)
                    .stroke(lineWidth: 3)
                    .foregroundColor(.blue)
                Image(card.content)
                    .resizable()
                    .scaledToFit()
                    .padding()
            }
            // start with the image flipped so when we rotate, it comes out looking right
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            // only show the image if the angle supports it
            // without this, the card started showing right away
            .opacity(flipRotation >= 90 ? 1 : 0)

            // BACK face
            // only show the back of the card if the angle supports it
            RoundedRectangle(cornerRadius: 10)
                .foregroundColor(.blue)
             //   .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(flipRotation < 90 ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // for wiggle
        .rotationEffect(rotationAngle)
        
        // for our flipping
        .rotation3DEffect(
            .degrees(flipRotation),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.4 //  adds depth realism
        )
        .onTapGesture(perform: onTap)
        
        // if we've flipping the card up or down, do the animation. reverse the direction if flipping down
        .onChange(of: isFaceUp) { _, newValue in
            withAnimation(.easeInOut(duration: flipDuration)) {
                flipRotation = newValue ? 180 : 0
            }
        }
        .onChange(of: isMatchWiggling) { _, shouldWiggle in
            if shouldWiggle { performWiggle(duration: 0.5) }
        }
        .onChange(of: isWinWiggling) { _, shouldWiggle in
            if shouldWiggle { performWiggle(duration: 2.0) }
        }
        .onAppear {
            flipRotation = isFaceUp ? 180 : 0
        }
    }

    // function to wiggle the card. We use this when we've matched 2 cards or win the game.
    
    @MainActor
    private func performWiggle(duration: Double) {
        let wiggles = Int(duration / wiggleStepDuration)
        let animation = Animation.linear(duration: wiggleStepDuration)
        let pause = UInt64(wiggleStepDuration * 1_000_000_000)

        Task {
            for i in 0..<wiggles {
                let angle = (i.isMultiple(of: 2) ? wiggleAngle : -wiggleAngle)
                withAnimation(animation) { rotationAngle = .degrees(angle) }
                try? await Task.sleep(nanoseconds: pause)
            }
            withAnimation(animation) { rotationAngle = .zero }
        }
    }
}

// this is for showing some confetti when we win
struct ConfettiParticle: Identifiable {
    let id = UUID()
    var x: Double
    var y: Double
    var size: Double
    var opacity: Double
    var duration: Double
}

// a view to show some confetti
struct ConfettiView: View {
    @State private var confetti = [ConfettiParticle]()
    let colors: [Color] = [
        .red, .blue, .green, .orange, .purple, .pink, .yellow,
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(confetti) { particle in
                    Circle()
                        .fill(colors.randomElement() ?? .blue)
                        .frame(width: particle.size, height: particle.size)
                        .position(x: particle.x, y: particle.y)
                        .opacity(particle.opacity)
                        .animation(
                            .easeOut(duration: particle.duration),
                            value: particle.y
                        )
                }
            }
            .onAppear {
                confetti = (0..<60).map { _ in
                    ConfettiParticle(
                        x: Double.random(in: 0...geo.size.width),
                        y: -20,
                        size: Double.random(in: 8...18),
                        opacity: 1,
                        duration: Double.random(in: 1.0...2.2)
                    )
                }
                withAnimation(.easeOut(duration: 2)) {
                    for idx in confetti.indices {
                        confetti[idx].y = geo.size.height + 40
                        confetti[idx].opacity = 0
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}



// this is the main view for the game
struct ContentView: View {

    // use a variable to determine if we are iphone or ipad
    // unfortunately we need to tweak because the screen ratios and sizes are so different
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    // ViewModel for MVVM
    @StateObject private var viewModel: GameViewModel

    init() {
        let manager = GameCenterManager()
        _viewModel = StateObject(wrappedValue: GameViewModel(gameCenterManager: manager))
    }

    // anything with @state will refresh the UI on change
    @State private var showingLeaderboard = false
    
    // the grid layout logic got nasty so moved to a function
    // this structure returns the calculations
    struct GridParameters {
        let itemWidth: CGFloat
        let itemHeight: CGFloat
        let columnCount: Int
        let spacing: CGFloat
        let columns: [GridItem]
    }

    // this is the logic to make the grid look nice
    // unfortunately it's a nightmare so it lives in a function
    
    @MainActor // Use @MainActor since it uses UIDevice.current
    // function to figure out all the layout shenanigans
    private func calculateGridParameters(
        geometry: GeometryProxy,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> GridParameters {
        
        // --- Setup and Context ---
        let isLandscape = geometry.size.width > geometry.size.height
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        // Use optional chaining with a fallback for horizontalSizeClass
       // let isRegular = horizontalSizeClass == .regular
       
        let spacing: CGFloat = isPhone ? 12 : 24

        // we use 4x6 for portrait
        // 8x3 on phone landscape and 6x4 on ipad landscape
        // that seemed to look best
        
        let aspectRatio: CGFloat = 2.0 / 3.0 // Width / Height
        let columnCount: Int = isLandscape ? (isPhone ? 8 : 6) : 4
        let rowCount: Int = isLandscape ? (isPhone ? 3 : 4) : 6

        // --- Available Space Calculation ---
        let totalHorizontalSpacing = spacing * (CGFloat(columnCount) - 1)
        let totalVerticalSpacing = spacing * (CGFloat(rowCount) - 1)

        let availableWidth = max(0, geometry.size.width - totalHorizontalSpacing)
        let availableHeight = max(0, geometry.size.height - totalVerticalSpacing)

        // --- Tile Size Calculation (Constrained by Width and Height) ---
        
        // Size if constrained by width
        let widthFromWidthConstraint = availableWidth / CGFloat(columnCount)
        let heightFromWidthConstraint = widthFromWidthConstraint / aspectRatio

        // Size if constrained by height
        let heightFromHeightConstraint = availableHeight / CGFloat(rowCount)
        let widthFromHeightConstraint = heightFromHeightConstraint * aspectRatio
        
        // Choose the smaller size to ensure the grid fits entirely
        let (itemWidth, itemHeight): (CGFloat, CGFloat) =
            (heightFromWidthConstraint <= heightFromHeightConstraint)
        ? (widthFromWidthConstraint, heightFromWidthConstraint)   // Width is limiting
            : (widthFromHeightConstraint, heightFromHeightConstraint) // Height is limiting

        // create our grid item array
        // we were very determined to find the best itemWidth
        let columns = Array(
            repeating: GridItem(.fixed(itemWidth), spacing: spacing),
            count: columnCount
        )
        
        // kick back our calculations
        return GridParameters(
            itemWidth: itemWidth,
            itemHeight: itemHeight,
            columnCount: columnCount,
            spacing: spacing,
            columns: columns
        )
    }

    
    // this is our main view...finally!
    var body: some View {
        // Device-based font sizing
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let textFont: Font = isPhone ? .headline : .title
        let buttonIconFont: Font = isPhone ? .body : .title
        
        ZStack {
            VStack(spacing: 8) {
                
                // top bar is info and buttons
                
                HStack(spacing: 8) {
                    Text("Flips: \(viewModel.flipCount)")
                        .font(textFont)
                        .foregroundColor(.blue)
                    Text(
                        {
                            if let best = viewModel.personalBest {
                                return "High Score: \(best)"
                            } else {
                                return "High Score: --"
                            }
                        }()
                    )
                    .font(textFont)
                    .foregroundColor(.green)

                    // new game icon
                    Button {
                        viewModel.newGame()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.blue)
                            .accessibilityLabel("New Game")
                            .font(buttonIconFont)
                    }
                    .help("Start a new game")

                    // global leadboard icon
                    Button {
                        viewModel.showLeaderboard()
                    } label: {
                        Label("Leaderboard", systemImage: "trophy")
                            .labelStyle(.iconOnly)
                            .foregroundColor(
                                viewModel.isAuthenticated ? .orange : .gray
                            )
                            .accessibilityLabel("Show Leaderboard")
                            .font(buttonIconFont)
                    }
                    .disabled(!viewModel.isAuthenticated)
                    .help("Show global leaderboard")
                }
                .padding(.bottom, 4)

                // do the grid via GeometryReader and function
                
                GeometryReader { geometry in
                    let params = calculateGridParameters(
                        geometry: geometry,
                        horizontalSizeClass: horizontalSizeClass
                    )

                    VStack(spacing: 8) {
                        // trusty LazyVGrid
                        LazyVGrid(columns: params.columns, spacing: params.spacing) {
                            
                            // spin through our cards
                            // send each TileCard our wiggle flags
                            
                            ForEach(viewModel.cards.indices, id: \.self) { idx in
                                TiledCard(
                                    card: viewModel.cards[idx],
                                    isFaceUp: viewModel.isPresentingFaceUp(idx),
                                    isMatchWiggling: viewModel.wigglingIndices.contains(idx),
                                    isWinWiggling: viewModel.showConfetti
                                ) {
                                    // secret sauce closure to handle flip card logic in the model
                                    viewModel.flip(cardAt: idx)
                                }
                                // Set the frame to our calculated size.
                                // The aspect ratio is already handled in the calculation.
                                .frame(width: params.itemWidth, height: params.itemHeight)
                                .allowsHitTesting(!viewModel.isInteractionDisabled)
                            }
                        }
                        // Keep grid full width; it will take remaining height
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()

            // if we won, show some confetti
            // this floats on top
            if viewModel.showConfetti {
                ConfettiView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // the confetti we throw up when we win
        .animation(.default, value: viewModel.showConfetti)

        // Bottom progress section pinned to the safe area
        // fitting the grid seems to be tricky
        // here we just pin to the bottom and that seems to do the trick
        .safeAreaInset(edge: .bottom) {
            let percent = Int((viewModel.progress * 100).rounded())
            HStack {
                VStack(spacing: 6) {
                    HStack {
                        Text("Progress")
                            .font(isPhone ? .subheadline : .headline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(percent)%")
                            .font(isPhone ? .subheadline : .headline)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    ProgressView(value: viewModel.progress)
                        .tint(.blue)
                        .animation(.easeInOut(duration: 0.25), value: viewModel.progress)
                }
                
            }
            // I tried setting the horizontal padding dynamically to no avail. 100 seems to look good for the various orientations and devices
            .padding(.horizontal,100)
            .padding(.top, 0)
            .padding(.bottom, 4)
            //.background(.ultraThinMaterial)
        }
        .sheet(isPresented: $viewModel.isShowingLeaderboard) {
            GameCenterView(leaderboardID: viewModel.leaderboardID)
                .ignoresSafeArea()
        }
    }
}

// Simple shared delegate to dismiss GKGameCenterViewController
final class GameCenterDelegate: NSObject, GKGameCenterControllerDelegate {
    static let shared = GameCenterDelegate()
    func gameCenterViewControllerDidFinish(
        _ gameCenterViewController: GKGameCenterViewController
    ) {
        gameCenterViewController.dismiss(animated: true)
    }
}

#Preview {
    ContentView()
}
