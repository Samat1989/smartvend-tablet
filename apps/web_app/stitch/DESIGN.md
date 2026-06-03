# Design System Document: The Kinetic Gourmet

## 1. Overview & Creative North Star
**Creative North Star: "The Culinary Pulse"**

This design system is engineered to transform the mundane act of mobile shopping into a high-energy, editorial experience. We are moving away from the "vending machine" aesthetic toward a "boutique digital market." To achieve this, we reject rigid grids in favor of **Intentional Kineticism**. 

The system utilizes oversized typography, asymmetrical image placements, and layered surfaces to create a sense of momentum. By treating the mobile screen as a high-end food magazine rather than a spreadsheet, we ensure every interaction feels premium, appetizing, and intentional. This is not just a utility; it is an invitation to consume.

---

## 2. Colors: Tonal Depth & The "No-Line" Rule
Our palette transitions from the heat of `primary` (#9C3F00) to the cool, expansive cleanliness of our `surface` tiers. 

### The "No-Line" Rule
**Explicit Instruction:** Do not use 1px solid borders to define sections. Visual separation must be achieved through:
- **Background Shifts:** Placing a `surface-container-lowest` card on a `surface-container-low` background.
- **Tonal Transitions:** Using the subtle shift between `surface` (#FAF5FB) and `surface-variant` (#E0DBE3) to denote content boundaries.

### Surface Hierarchy & Nesting
Treat the UI as a physical stack of premium materials. 
*   **Base:** `surface` (The foundation).
*   **The Hero Layer:** `surface-container-lowest` (Used for primary content cards to create a "lifted" feel).
*   **The Inset Layer:** `surface-container-high` (Used for search bars or secondary groupings to create a "pressed-in" feel).

### The "Glass & Gradient" Rule
To elevate the "energetic" feel, use **Glassmorphism** for floating action headers or navigation bars. Utilize `surface` at 80% opacity with a `20px` backdrop blur. 
*   **Signature Textures:** Main CTAs should never be flat. Apply a subtle linear gradient from `primary` (#9C3F00) to `primary-container` (#FF7A2F) at a 135-degree angle to provide a "glow" that mimics fresh, vibrant produce.

---

## 3. Typography: Editorial Authority
We use a dual-font strategy to balance high-energy appetite with functional legibility.

*   **Display & Headline (Lexend):** Used for impact. The rounded nature of Lexend provides a "friendly" entry point but, when scaled to `display-lg` (3.5rem), it acts as a bold, structural element. Use tight letter-spacing for headlines to create a "packed" and energetic look.
*   **Title & Body (Inter):** The workhorse. Inter provides the technical precision needed for nutritional facts and pricing. Use `title-md` for product names to ensure they stand out against high-contrast imagery.
*   **Labels (Lexend):** Small but mighty. All-caps Lexend for `label-sm` creates a sophisticated, "tagged" look for categories (e.g., "ORGANIC", "NEW").

---

## 4. Elevation & Depth: The Layering Principle
We do not use shadows to hide poor layout; we use them to simulate natural light.

*   **Tonal Layering:** Hierarchy is primarily achieved by stacking `surface-container` tiers. A `surface-container-lowest` card sitting on a `surface-container-low` background provides a soft, organic lift.
*   **Ambient Shadows:** For floating elements (like a "Add to Cart" fab), use an extra-diffused shadow: `offset-y: 8px`, `blur: 24px`, `color: rgba(47, 46, 50, 0.06)`. The shadow must be tinted with the `on-surface` color to avoid a "dirty" grey look.
*   **The "Ghost Border" Fallback:** If a boundary is strictly required for accessibility, use the `outline-variant` token at **15% opacity**. Never use a 100% opaque stroke.
*   **Depth through Blur:** Use `backdrop-blur` on navigation overlays to keep the user grounded in the "market" while they interact with menus.

---

## 5. Components

### Buttons & Interaction
*   **Primary Action:** Oversized (min-height: 56px) with a `xl` (3rem) corner radius. Use the signature `primary` to `primary-container` gradient. 
*   **Secondary Action:** `surface-container-highest` background with `on-surface` text. No border.
*   **Tertiary/Ghost:** `on-primary-fixed-variant` text with no container.

### Product Cards (The Hero)
*   **Constraint:** Forbid the use of divider lines.
*   **Layout:** Use `surface-container-lowest` as the card base. Product imagery should "break the box"—allow high-quality PNGs of food to slightly overlap the card boundaries for a 3D, appetizing effect.
*   **Spacing:** Use `md` (1.5rem) padding internally to give the product "room to breathe."

### Input Fields
*   **Style:** Minimalist. `surface-container-low` background with a `sm` (0.5rem) bottom radius only, creating a modern "shelf" look. 
*   **States:** On focus, the bottom "shelf" transitions to `primary` (#9C3F00) with a 2px height.

### Micromarket-Specific Components
*   **The "Quick-Add" Stepper:** A horizontal pill-shaped component (`full` roundedness) using `secondary-container`. Use `on-secondary-container` for the plus/minus icons to maintain high contrast.
*   **Nutritional Badges:** Small, circular `tertiary-container` icons that float in the top-right of product images, indicating "High Protein" or "Vegan."

---

## 6. Do's and Don'ts

### Do:
*   **Do** use asymmetrical layouts. Let an image take up 60% of the width while text takes up 40%.
*   **Do** use `display-lg` typography for promotional sections, letting the text be the "art."
*   **Do** prioritize large tap targets (minimum 48x48dp) to accommodate "on-the-go" micromarket users.

### Don't:
*   **Don't** use standard "Grey" (#808080). Use our `on-surface-variant` (#5D5B5F) which is keyed to our charcoal and orchid base.
*   **Don't** use 1px dividers between list items. Use 16px of vertical white space or a subtle `surface` color shift.
*   **Don't** use sharp corners. Everything in this system must feel "friendly" and "approachable," adhering to the `DEFAULT` (1rem) or `xl` (3rem) roundedness scale.

---
**Director's Note:** This system succeeds when it feels alive. Every scroll should feel like a discovery, and every tap should feel like a premium interaction. Avoid the "template trap"—if a layout feels too symmetrical, break it.