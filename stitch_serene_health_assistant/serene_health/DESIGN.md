---
name: Serene Health
colors:
  surface: '#f8fafb'
  surface-dim: '#d8dadb'
  surface-bright: '#f8fafb'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f2f4f5'
  surface-container: '#eceeef'
  surface-container-high: '#e6e8e9'
  surface-container-highest: '#e1e3e4'
  on-surface: '#191c1d'
  on-surface-variant: '#414942'
  inverse-surface: '#2e3132'
  inverse-on-surface: '#eff1f2'
  outline: '#717971'
  outline-variant: '#c1c9bf'
  surface-tint: '#376847'
  primary: '#316342'
  on-primary: '#ffffff'
  primary-container: '#4a7c59'
  on-primary-container: '#e1ffe5'
  inverse-primary: '#9dd3aa'
  secondary: '#3e6659'
  on-secondary: '#ffffff'
  secondary-container: '#c0ecdc'
  on-secondary-container: '#446c5f'
  tertiary: '#405d6a'
  on-tertiary: '#ffffff'
  tertiary-container: '#587683'
  on-tertiary-container: '#eff9ff'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#b9efc5'
  primary-fixed-dim: '#9dd3aa'
  on-primary-fixed: '#00210e'
  on-primary-fixed-variant: '#1e5031'
  secondary-fixed: '#c0ecdc'
  secondary-fixed-dim: '#a5d0c0'
  on-secondary-fixed: '#002018'
  on-secondary-fixed-variant: '#264e42'
  tertiary-fixed: '#c8e7f7'
  tertiary-fixed-dim: '#accbda'
  on-tertiary-fixed: '#001f29'
  on-tertiary-fixed-variant: '#2d4b57'
  background: '#f8fafb'
  on-background: '#191c1d'
  surface-variant: '#e1e3e4'
typography:
  display-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-md:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
    letterSpacing: -0.01em
  headline-sm:
    fontFamily: Inter
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
  title-lg:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: '500'
    lineHeight: 24px
  body-lg:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  label-md:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16px
    letterSpacing: 0.05em
  headline-lg-mobile:
    fontFamily: Inter
    fontSize: 28px
    fontWeight: '600'
    lineHeight: 36px
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  base: 4px
  xs: 8px
  sm: 12px
  md: 16px
  lg: 24px
  xl: 32px
  container-margin: 20px
  gutter: 16px
---

## Brand & Style
The design system is centered on a "Clinical Zen" philosophy. It balances the rigor of medical data with the tranquility of a wellness retreat. The target audience includes patients managing chronic conditions and wellness-focused individuals who require a low-stress interface. 

The visual style is a hybrid of **Modern Corporate** and **Soft Minimalism**. It prioritizes heavy whitespace to reduce cognitive load and uses gentle transitions to evoke a sense of proactive care. The emotional response is one of reliability, safety, and quiet competence.

## Colors
This design system utilizes a palette of organic, muted tones to promote physiological calmness.
- **Primary (Sage Green):** Used for primary actions and brand presence. It represents growth and health.
- **Secondary (Soft Mint):** Used for success states and background accents.
- **Tertiary (Gentle Blue):** Reserved for information, progress indicators, and secondary supportive elements.
- **Neutral (Clinical White/Grey):** A range of off-whites and cool greys to ensure the UI feels clean but not "sterile" or harsh. 

Text should primarily use a deep slate grey (#2D3748) rather than pure black to maintain the soft aesthetic while preserving high contrast for accessibility.

## Typography
Inter is chosen for its exceptional legibility in data-heavy contexts. The hierarchy is intentionally flat to prevent the UI from feeling overwhelming.
- **Headlines:** Use semi-bold weights with slight negative letter-spacing for a modern, compact feel.
- **Body Text:** Standard weight with generous line height (1.5x) to assist users with visual fatigue or reading difficulties.
- **Data Points:** When displaying medical metrics (e.g., heart rate, blood pressure), use `headline-md` or `display-lg` to ensure they are the first thing a user sees.

## Layout & Spacing
The layout follows a 4-column fluid grid for mobile. The philosophy is "breathable data," where vertical rhythm is strictly enforced to create a sense of order.
- **Margins:** 20px side margins ensure content does not feel cramped against the screen edges.
- **Padding:** Use `lg` (24px) padding within cards to prevent data from feeling "trapped."
- **Stacking:** Elements should follow an 8px-based scale for consistent vertical gaps. Larger gaps (32px+) should be used between unrelated sections to clearly delineate different health metrics.

## Elevation & Depth
Elevation is communicated through **Tonal Layering** and **Ambient Shadows**. This design system avoids high-contrast shadows to keep the interface light and airy.
- **Level 0 (Background):** The neutral background color (#F8FAFB).
- **Level 1 (Cards/Containers):** Pure white (#FFFFFF) with a very soft, diffused shadow (0px 4px 20px rgba(0, 0, 0, 0.04)).
- **Level 2 (Active/Floating):** Used for FABs or active selection, with a slightly deeper shadow (0px 8px 24px rgba(74, 124, 89, 0.1)) to provide a hint of the primary color in the depth.
- **Borders:** Use a 1px solid border (#E2E8F0) for input fields and dividers instead of shadows to maintain a clean, clinical structure.

## Shapes
The shape language is approachable and soft.
- **Standard Elements:** Buttons and input fields use a `0.5rem` (8px) radius.
- **Large Containers:** Content cards and bottom sheets use `1rem` (16px) or `1.5rem` (24px) for a more organic, friendly appearance.
- **Selection Indicators:** Use pill-shaped (full radius) buttons for toggles and chips to distinguish them from actionable primary buttons.

## Components
- **Buttons:** Primary buttons use the Sage Green background with white text. Secondary buttons use a Sage Green outline with a subtle mint-tinted background on hover.
- **Cards:** The primary vehicle for health data. Every card should have a white background, soft corner radius, and contain a clear header.
- **Input Fields:** Use a subtle grey border that turns Sage Green on focus. Labels should always be visible (not floating) for better accessibility.
- **Chips:** Used for filtering health categories. Use pill shapes with `tertiary` (blue) backgrounds for a calming, non-urgent interactive feel.
- **Progress Bars:** Use a thick 8px track with rounded ends. The track is a light grey, and the fill is a gradient from Secondary to Primary color to symbolize progress and health.
- **Empty States:** Use soft, illustrative icons in the tertiary blue color to keep the mood light even when data is missing.