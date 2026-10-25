import SwiftUI

/// A titled slider that shows its value with units.
///
/// `range` and `step` are in the stored value's units. `displayFactor` converts the stored value
/// for the label (metres shown as centimetres, seconds as milliseconds).
struct SliderRow: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  var isLogarithmic = false
  var displayFactor = 1.0
  var fractionDigits = 1
  var unit = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent(title) {
        Text(valueText)
          .monospacedDigit()
      }
      Slider(value: position, in: positionRange)
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
    }
  }

  private var valueText: String {
    let shown = value * displayFactor
    return shown.formatted(.number.precision(.fractionLength(fractionDigits))) + unit
  }

  private var positionRange: ClosedRange<Double> {
    isLogarithmic ? log2(range.lowerBound)...log2(range.upperBound) : range
  }

  /// The slider's own coordinate, snapped to `step` in the stored value's units.
  private var position: Binding<Double> {
    Binding(
      get: { isLogarithmic ? log2(value) : value },
      set: { newPosition in
        let raw = isLogarithmic ? pow(2, newPosition) : newPosition
        let snapped = (raw / step).rounded() * step
        value = min(max(snapped, range.lowerBound), range.upperBound)
      })
  }
}
