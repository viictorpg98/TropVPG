//
//  QueueListView.swift
//  Trop
//
//  La lista de la cola con una UICollectionView: desplazar, tocar una cancion, quitar deslizando y reordenar arrastrando el
//  asa son los del sistema (fluidos y sin pelearse entre si, que es lo que pasaba con gestos de SwiftUI dentro de un
//  ScrollView). Las filas siguen siendo `QueueSongRow`.
//

import SwiftUI
import UIKit

/// La lista de la cola, que avisa cada vez que se coloca (para centrar la cancion que suena cuando ya tiene tamano).
final class QueueCollectionView: UICollectionView {
    var onLayout: (() -> Void)?
    var onAttach: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    /// Cada vez que la lista entra en pantalla (tambien si se reutiliza al reabrir la cola).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onAttach?() }
    }
}

struct QueueListView: UIViewRepresentable {
    struct Item {
        let id: String
        let index: Int
        let song: SongItem
        let isCurrent: Bool
        let isPlayed: Bool
    }

    let items: [Item]
    let currentIndex: Int
    /// `true` si la lista puede desplazarse sola a la cancion que suena (no si la estas moviendo).
    let shouldFollow: () -> Bool
    let onSelect: (Int) -> Void
    let onDelete: (Int) -> Void
    let onReorder: ([SongItem]) -> Void
    let onUserScroll: () -> Void
    /// Con un filtro de busqueda puesto no se reordena (las posiciones no son las de la cola).
    var allowsReorder = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        configuration.trailingSwipeActionsConfigurationProvider = { indexPath in
            coordinator.swipeActions(at: indexPath)
        }
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        let collectionView = QueueCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.onLayout = { [weak coordinator] in coordinator?.viewDidLayout() }
        collectionView.onAttach = { [weak coordinator] in coordinator?.viewDidAttach() }
        collectionView.backgroundColor = .clear
        collectionView.overrideUserInterfaceStyle = .dark
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsVerticalScrollIndicator = false
        collectionView.delegate = coordinator
        coordinator.attach(collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(items: items, currentIndex: currentIndex)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        var parent: QueueListView
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private weak var collectionView: UICollectionView?
        private var itemsByID: [String: Item] = [:]
        private var hasApplied = false
        private var lastCurrentIndex: Int?
        /// Posicion (en la lista) a la que centrar al abrir, pendiente de que la lista tenga tamano y alturas reales.
        private var pendingInitialScroll: Int?
        private var userDragged = false
        private var currentPosition = 0

        // Reordenar
        private var reorderGesture: UILongPressGestureRecognizer?
        private var isReordering = false
        private var pendingItems: [Item]?
        private var displayLink: CADisplayLink?
        private weak var liftedCell: UICollectionViewCell?

        /// Zona de la derecha (donde esta el asa) desde la que se arrastra para reordenar.
        private let handleZone: CGFloat = 76

        init(_ parent: QueueListView) {
            self.parent = parent
        }

        func attach(_ collectionView: UICollectionView) {
            self.collectionView = collectionView

            let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
                guard let self, let item = self.itemsByID[id] else { return }
                cell.automaticallyUpdatesBackgroundConfiguration = false
                cell.backgroundConfiguration = .clear()
                cell.contentConfiguration = UIHostingConfiguration {
                    QueueSongRow(song: item.song, isCurrent: item.isCurrent, isPlayed: item.isPlayed)
                        .frame(height: 56)
                        .background {
                            if item.isCurrent {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.08))
                                    .padding(.horizontal, 12)
                            }
                        }
                        .environment(SettingsStore.shared)
                        .environment(\.colorScheme, .dark)
                }
                .margins(.all, 0)
            }

            let dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { collectionView, indexPath, id in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            dataSource.reorderingHandlers.canReorderItem = { _ in true }
            dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
                self?.didReorder(transaction)
            }
            self.dataSource = dataSource

            let press = UILongPressGestureRecognizer(target: self, action: #selector(handleReorder(_:)))
            press.minimumPressDuration = 0.18
            press.delegate = self
            collectionView.addGestureRecognizer(press)
            reorderGesture = press
        }

        // MARK: Datos

        func update(items: [Item], currentIndex: Int) {
            // Mientras se arrastra una fila no se toca la lista; lo ultimo que llego se aplica al soltar.
            if isReordering {
                pendingItems = items
                return
            }
            apply(items, animated: hasApplied)
            // La posicion de la que suena DENTRO de la lista (con un filtro de busqueda no es el indice de la cola).
            let position = items.firstIndex(where: \.isCurrent) ?? currentIndex
            currentPosition = position
            if !hasApplied {
                hasApplied = true
                // Al abrir, la lista aun no tiene tamano ni alturas reales (las filas se miden al pintarse): centrar ahora
                // fallaba sobre todo con canciones lejanas. Se centra cuando ya esta puesta, y otra vez un momento despues.
                pendingInitialScroll = position
                collectionView?.setNeedsLayout()
            } else if lastCurrentIndex != currentIndex, parent.shouldFollow() {
                scrollToCurrent(position, animated: true)
            }
            lastCurrentIndex = currentIndex
        }

        private func apply(_ items: [Item], animated: Bool) {
            itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            let ids = items.map(\.id)
            snapshot.appendItems(ids)
            snapshot.reconfigureItems(ids)
            dataSource?.apply(snapshot, animatingDifferences: animated)
        }

        /// La lista entra en pantalla: se centra la cancion que suena (y vuelve a valer el centrado automatico).
        func viewDidAttach() {
            guard hasApplied else { return }
            userDragged = false
            pendingInitialScroll = currentPosition
            collectionView?.setNeedsLayout()
        }

        /// Lo llama la lista cada vez que se coloca: la primera vez que ya tiene tamano, centra la cancion que suena.
        func viewDidLayout() {
            guard let index = pendingInitialScroll, let collectionView, collectionView.bounds.height > 0 else { return }
            pendingInitialScroll = nil
            DispatchQueue.main.async { [weak self] in
                self?.centerOnOpen(index)
                // Con las alturas ya medidas, una segunda vez deja la fila bien en el centro (salvo que ya hayas movido la lista).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, !self.userDragged else { return }
                    self.centerOnOpen(index)
                }
            }
        }

        private func centerOnOpen(_ index: Int) {
            guard let collectionView, !userDragged else { return }
            collectionView.layoutIfNeeded()
            scrollToCurrent(index, animated: false)
            collectionView.layoutIfNeeded()
            scrollToCurrent(index, animated: false)
        }

        private func scrollToCurrent(_ index: Int, animated: Bool) {
            guard let collectionView, index >= 0, index < collectionView.numberOfItems(inSection: 0) else { return }
            collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: animated)
        }

        // MARK: Tocar, desplazar, quitar

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: true)
            guard let id = dataSource?.itemIdentifier(for: indexPath), let item = itemsByID[id] else { return }
            parent.onSelect(item.index)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            userDragged = true
            parent.onUserScroll()
        }

        func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let id = dataSource?.itemIdentifier(for: indexPath), let item = itemsByID[id] else { return nil }
            let delete = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completion in
                self?.parent.onDelete(item.index)
                completion(true)
            }
            delete.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [delete])
        }

        // MARK: Reordenar

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === reorderGesture, let collectionView else { return true }
            guard parent.allowsReorder else { return false }
            let point = gestureRecognizer.location(in: collectionView)
            return point.x > collectionView.bounds.width - handleZone && collectionView.indexPathForItem(at: point) != nil
        }

        @objc private func handleReorder(_ gesture: UILongPressGestureRecognizer) {
            guard let collectionView else { return }
            switch gesture.state {
            case .began:
                guard let indexPath = collectionView.indexPathForItem(at: gesture.location(in: collectionView)),
                      collectionView.beginInteractiveMovementForItem(at: indexPath) else { return }
                isReordering = true
                parent.onUserScroll()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                lift(collectionView.cellForItem(at: indexPath))
                startDisplayLink()
            case .changed:
                guard isReordering else { return }
                collectionView.updateInteractiveMovementTargetPosition(gesture.location(in: collectionView))
            case .ended:
                guard isReordering else { return }
                stopDisplayLink()
                collectionView.endInteractiveMovement()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                finishReordering()
            default:
                guard isReordering else { return }
                stopDisplayLink()
                collectionView.cancelInteractiveMovement()
                finishReordering()
            }
        }

        /// La fila que se arrastra se levanta (un poco mas grande y con sombra).
        private func lift(_ cell: UICollectionViewCell?) {
            guard let cell else { return }
            liftedCell = cell
            cell.layer.masksToBounds = false
            cell.layer.shadowColor = UIColor.black.cgColor
            cell.layer.shadowOpacity = 0.4
            cell.layer.shadowRadius = 10
            cell.layer.shadowOffset = CGSize(width: 0, height: 4)
            UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                cell.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
            }
        }

        private func drop() {
            guard let cell = liftedCell else { return }
            liftedCell = nil
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                cell.transform = .identity
            } completion: { _ in
                cell.layer.shadowOpacity = 0
            }
        }

        private func didReorder(_ transaction: NSDiffableDataSourceTransaction<Int, String>) {
            let ids = transaction.finalSnapshot.itemIdentifiers
            let songs = ids.compactMap { itemsByID[$0]?.song }
            guard songs.count == ids.count else { return }
            parent.onReorder(songs)
        }

        /// Pasado un momento (cuando el sistema ya ha terminado de colocar la fila) se vuelve a hacer caso a la lista.
        private func finishReordering() {
            drop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                self.isReordering = false
                if let pending = self.pendingItems {
                    self.pendingItems = nil
                    self.update(items: pending, currentIndex: self.parent.currentIndex)
                }
            }
        }

        // MARK: Desplazamiento automatico al arrastrar cerca de los bordes

        private func startDisplayLink() {
            displayLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick() {
            guard let collectionView, let gesture = reorderGesture, isReordering else { return }
            let location = gesture.location(in: collectionView)
            let top = collectionView.contentOffset.y
            let bottom = top + collectionView.bounds.height
            let edge: CGFloat = 70
            var delta: CGFloat = 0
            if location.y < top + edge {
                delta = -min(14, (top + edge - location.y) / 4 + 2)
            } else if location.y > bottom - edge {
                delta = min(14, (location.y - (bottom - edge)) / 4 + 2)
            }
            guard delta != 0 else { return }
            let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
            let next = min(max(top + delta, 0), maxOffset)
            guard next != top else { return }
            collectionView.contentOffset.y = next
            collectionView.updateInteractiveMovementTargetPosition(gesture.location(in: collectionView))
        }
    }
}
