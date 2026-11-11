//
//  SettingsComponents.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//
//  Estilo de los Ajustes de Sonar: sin tarjetas, el icono del color de acento, el titulo y, a la derecha, el valor.
//

import SwiftUI

/// El icono (del color de acento) y el titulo de una fila.
struct SettingsLabel: View {
    @Environment(SettingsStore.self) private var settings
    let title: String
    let icon: String?

    var body: some View {
        HStack(spacing: 14) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .foregroundStyle(settings.accentColor)
                    .frame(width: 26)
            }
            Text(LocalizedStringKey(title))
        }
    }
}

extension View {
    /// Lista plana, sin tarjetas, con separadores finos.
    func sonarSettingsList() -> some View {
        listStyle(.plain)
            .listRowSeparatorTint(Color.primary.opacity(0.12))
    }
}

struct SettingsNavigationRow<Destination: View>: View {
    @Environment(SettingsStore.self) private var settings
    let title: String
    let icon: String
    var value: String?
    @ViewBuilder var destination: () -> Destination

    init(_ title: String, icon: String, value: String? = nil, @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.icon = icon
        self.value = value
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                SettingsLabel(title: title, icon: icon)
                Spacer(minLength: 8)
                if let value {
                    Text(LocalizedStringKey(value))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(settings.accentColor)
    }
}

struct SettingsToggleRow: View {
    @Environment(SettingsStore.self) private var settings
    let title: String
    let icon: String?
    @Binding var isOn: Bool

    init(_ title: String, icon: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.icon = icon
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsLabel(title: title, icon: icon)
        }
        .tint(settings.toggleTint)
    }
}

struct SettingsPickerRow<T: SettingsOption>: View {
    @Environment(SettingsStore.self) private var settings
    let title: String
    let icon: String?
    @Binding var selection: T

    init(_ title: String, icon: String? = nil, selection: Binding<T>) {
        self.title = title
        self.icon = icon
        self._selection = selection
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(Array(T.allCases)) { option in
                Text(LocalizedStringKey(option.displayName)).tag(option)
            }
        } label: {
            SettingsLabel(title: title, icon: icon)
        }
        .id(settings.accentName)
        .tint(settings.accentColor)
    }
}

struct SettingsStepperRow: View {
    let title: String
    let icon: String?
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    @Binding var value: Double

    init(_ title: String,
         icon: String? = nil,
         value: Binding<Double>,
         in range: ClosedRange<Double> = 0.5...2.0,
         step: Double = 0.1,
         format: @escaping (Double) -> String = { String(format: "%.1fx", $0) }) {
        self.title = title
        self.icon = icon
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        Stepper {
            HStack {
                SettingsLabel(title: title, icon: icon)
                Spacer(minLength: 8)
                Text(format(value))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } onIncrement: {
            value = min(value + step, range.upperBound)
        } onDecrement: {
            value = max(value - step, range.lowerBound)
        }
    }
}

struct SettingsLinkRow: View {
    let title: String
    let icon: String
    let url: URL

    init(_ title: String, icon: String, url: URL) {
        self.title = title
        self.icon = icon
        self.url = url
    }

    var body: some View {
        Link(destination: url) {
            SettingsLabel(title: title, icon: icon)
        }
    }
}
