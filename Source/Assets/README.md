# Harbor icon

Final design: a flat solid-blue rounded tile with a white connect/chain-link symbol. No gradient, lighting, texture, or three-dimensional effects.

The production artwork is deterministic vector geometry in Harbor.svg and build_icon.swift. The earlier built-in imagegen concepts were rejected and are not included or used in the application. The final design follows the user's instruction: “平面化风格，上面一个 connect 图标”.

build_icon.swift directly renders the geometry at16,32,64,128,256,512,1024pixels. Harbor.icns includes macOS1x/2x icon representations. Sources/Harbor/BrandIcon.swift draws the corresponding monochrome menu-bar mark. The menu item remains28points wide.
