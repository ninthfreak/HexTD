class_name GameState
## Carries the player's choice from the menu into the game scene.
## Static vars persist across scene changes.

static var selected_path := ""    # "" means use the generated demo map
static var mode := "sandbox"      # "sandbox" | "game" | "tutorial"
