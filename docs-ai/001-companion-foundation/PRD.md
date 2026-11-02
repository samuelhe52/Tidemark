Product Requirements — Floating macOS Companion

1. Core Concept

A beautiful, customizable, animated desktop companion for macOS that provides quick access to AI coding-agent usage limits and other metrics.

It should feel like a living part of the desktop, rather than a conventional monitoring widget.

2. Core Requirements

Floating & Auto-Hiding

* Floats above ordinary application windows.
* Can attach to the edge of the screen.
* Automatically retracts into the edge when inactive, minimizing visual obstruction.
* On hover, smoothly emerges onto the screen and expands.
* Retracts when the pointer leaves.
* The hidden shape need not match its fully visible shape.

Expandable Dashboard

* Displays usage limits for coding agents, especially Claude Code and Codex.
* Shows remaining quotas, reset countdowns, and other relevant usage metrics.
* Reads data primarily from CC Switch's local store.
* Provides an attractive, easily readable dashboard without requiring users to open CC Switch.

Customizable Appearance

* Default: a spherical, softly animated orb—not a geographic globe.
* Supports alternative shapes and appearances.
* The companion could eventually become a fully animated desktop pet.
* Different appearances should share the same underlying functionality.
* Customization should extend to animations and behaviors, not merely colors.

3. Visual Design & Interaction

The intended experience

Hidden -> Subtle edge presence
Revealed -> Animated orb or pet
Expanded -> Interactive metrics panel

The application should prioritize:

* Aesthetic excellence: distinctive, elegant, and visually delightful—not utilitarian or generic.
* Fluid motion: natural transitions with carefully tuned easing, spring animations, and subtle idle movement.
* Unobtrusiveness: virtually disappears when the user is concentrating.
* Personality: should feel like a companion with character, even in its default orb form.
* Consistency: the dashboard, companion, animations, and customization should belong to one coherent visual language.

4. Architecture & Extensibility

Keep three concerns independent:

* Companion engine: positioning, docking, hovering, animations, and interaction.
* Appearance system: interchangeable orb, abstract shapes, animated pets, and future custom skins.
* Data layer: CC Switch integration, usage limits, metrics, and future data providers.

This allows the application to evolve from a lightweight quota monitor into a richer desktop companion without redesigning its foundations.

5. Existing Reference

Codenotch is the closest functional reference.

It demonstrates the feasibility of edge docking, auto-hiding, hover expansion, and agent usage monitoring.

However, it does not meet your aesthetic expectations. Its visual design feels too plain and utilitarian.

The goal is to retain the useful interaction model while pursuing a substantially more polished, expressive, and customizable visual experience.

One-sentence vision:

A beautifully animated, shape-shifting macOS desktop companion that quietly lives at the screen's edge, comes alive on hover, and reveals your coding agents' usage and activity through an elegant, customizable interface.
