import unicodedata

application = defines["application"]
instruction = defines["instruction"]
background = defines["background"]
volume_icon = defines["volume_icon"]
instruction_name = unicodedata.normalize("NFD", "ПЕРВЫЙ ЗАПУСК.txt")

format = "UDZO"
filesystem = "HFS+"
compression_level = 9
size = "128M"
icon = volume_icon
files = [
    (application, "RecoveryApp.app"),
    (instruction, instruction_name),
]
symlinks = {"Программы": "/Applications"}
background = background
window_rect = ((160, 120), (660, 500))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 88
text_size = 13
arrange_by = None
show_icon_preview = True
icon_locations = {
    "RecoveryApp.app": (175, 205),
    "Программы": (485, 205),
    instruction_name: (330, 315),
}
