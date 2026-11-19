local M = {}
local config = require("godot.config")
local icons = {}
local function register(family, glyph, class_names)
  for class in class_names:gmatch("%S+") do
    icons[class] = { glyph, "GodotTree" .. family }
  end
end

-- Use the editor's blue for 2D, coral for 3D, green for Control and silver for Node.
-- Dimension-specific variants often share the same silhouette.
local function spatial(glyph, names)
  for class in names:gmatch("%S+") do
    register("Node2D", glyph, class .. "2D")
    register("Node3D", glyph, class .. "3D")
  end
end

register("Node", "󰐾", "Node")
register("Node", "󰔛", "Timer")
register("Node", "󰕾", "AudioStreamPlayer")
register("Node", "󰽙", "CanvasLayer ParallaxBackground")
register("Node", "󰪐", "AnimationMixer AnimationPlayer")
register("Node", "󰙅", "AnimationTree")
register("Node", "󰹟", "Window Viewport SubViewport Popup PopupPanel PopupMenu FileDialog AcceptDialog ConfirmationDialog")
register("Node", "󰩦", "PackedScene InstancePlaceholder")
register("Node", "󰀘", "WorldEnvironment")
register("Node2D", "󰕟", "Node2D CanvasGroup CanvasModulate BackBufferCopy ParallaxLayer")
register("Node2D", "󰋁", "TileMap TileMapLayer")
register("Node2D", "󰳾", "TouchScreenButton")
register("Node3D", "󰆧", "Node3D FogVolume Decal VoxelGI")
register("Node3D", "󰋁", "GridMap")
spatial("󰥶", "Sprite")
spatial("󰋯", "AnimatedSprite")
spatial("󰩬", "Area")
spatial("󰠲", "CollisionShape")
spatial("󰕠", "CollisionPolygon Polygon")
spatial("󰖡", "PhysicsBody RigidBody")
spatial("󰜎", "CharacterBody")
spatial("󰹟", "StaticBody AnimatableBody")
spatial("󰆣", "Marker")
spatial("󰕡", "Path Line")
spatial("󰴠", "PathFollow")
spatial("󰟙", "NavigationAgent NavigationLink NavigationRegion NavigationObstacle")
spatial("󰵝", "Camera")
spatial("󰙴", "CPUParticles GPUParticles")
spatial("󰛐", "VisibleOnScreenNotifier VisibleOnScreenEnabler")
spatial("󰕾", "AudioStreamPlayer AudioListener")
spatial("󰌶", "Light DirectionalLight PointLight OmniLight SpotLight AreaLight")
spatial("󰑃", "RayCast ShapeCast")
spatial("󰆩", "MeshInstance MultiMeshInstance")
spatial("󰂹", "Bone PhysicalBone Skeleton")
spatial("󰌹", "Joint PinJoint")
register("Node3D", "󰊄", "Label3D")
register("Control", "󰀁", "Control GraphEdit GraphElement GraphFrame GraphNode ReferenceRect VirtualJoystick")
register("Control", "󱇙", [[Container BoxContainer HBoxContainer VBoxContainer GridContainer MarginContainer
  CenterContainer PanelContainer SplitContainer HSplitContainer VSplitContainer ScrollContainer FlowContainer
  HFlowContainer VFlowContainer TabContainer SubViewportContainer FoldableContainer AspectRatioContainer]])
register("Control", "󰳾", "BaseButton Button CheckBox CheckButton OptionButton MenuButton LinkButton TextureButton")
register("Control", "󰊄", "Label RichTextLabel")
register("Control", "󰧭", "TextEdit CodeEdit LineEdit")
register("Control", "󰸌", "ColorRect ColorPicker ColorPickerButton")
register("Control", "󰥶", "TextureRect NinePatchRect")
register("Control", "󰭶", "Panel TabBar MenuBar HSeparator VSeparator Separator")
register("Control", "󰹟", "ProgressBar TextureProgressBar Range SpinBox Slider VSlider HSlider ScrollBar VScrollBar HScrollBar")
register("Control", "󰙅", "Tree ItemList")
register("Control", "󰈰", "VideoStreamPlayer")

function M.get(node)
  local class = node.native_type or node.type or (node.instance and "PackedScene") or "Node"
  local fallback = "Node" .. (class:match("([23]D)$") or "")
  local icon = icons[class] or icons[fallback]
  if config.options.scene_icons == "godot" then
    local official = require("godot.official_icon_map")
    return { vim.fn.nr2char(official[class] or official[fallback]), icon[2] }
  end
  return icon
end

function M.known(class)
  return icons[class] ~= nil or require("godot.official_icon_map")[class] ~= nil
end

return M
