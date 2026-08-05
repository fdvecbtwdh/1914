extends Node

## 全局游戏状态管理
## 当前游戏模式：local（本地对战）/ online（在线对战）
var game_mode: String = "local"

func _ready() -> void:
    print("[GameManager] Initialized")
