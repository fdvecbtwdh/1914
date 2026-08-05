extends Node

## 游戏启动时扫描 data/cards/ 目录，加载所有卡牌 JSON
## 注意：本脚本以 Autoload 方式注册（project.godot 中名为 CardDataLoader），
## 因此这里不再声明 class_name（会与 Autoload 单例名冲突）。
##
## 说明：GDScript 一个脚本文件只能声明一个 class_name（顶层类），
## 因此 CardData 作为本文件的内部类（extends Resource）实现，
## 外部通过 CardDataLoader.CardData 访问。

var cards: Dictionary = {}  # {id: CardData}

func _ready() -> void:
    load_all_cards()

func load_all_cards() -> Dictionary:
    cards.clear()
    _load_from_dir("res://data/cards/units/")
    _load_from_dir("res://data/cards/orders/")
    print("[CardDataLoader] Loaded %d cards" % cards.size())
    return cards

func _load_from_dir(dir_path: String) -> void:
    var dir = DirAccess.open(dir_path)
    if dir == null:
        printerr("[CardDataLoader] Cannot open directory: %s" % dir_path)
        return
    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if file_name.ends_with(".json"):
            _load_card(dir_path + file_name)
        file_name = dir.get_next()
    dir.list_dir_end()

func _load_card(file_path: String) -> void:
    var file = FileAccess.open(file_path, FileAccess.READ)
    if file == null:
        printerr("[CardDataLoader] Cannot read file: %s" % file_path)
        return
    var json_text = file.get_as_text()
    file.close()
    var json = JSON.new()
    var error = json.parse(json_text)
    if error != OK:
        printerr("[CardDataLoader] JSON parse error in %s" % file_path)
        return
    var data = json.get_data()
    var card = CardData.new()
    card.id = data.get("id", "")
    card.card_name = data.get("name", "")
    card.nation = data.get("nation", "")
    card.type = data.get("type", "")
    card.unit_class = data.get("unit_class", "")
    card.cost_g = data.get("cost_g", 0)
    card.cost_k = data.get("cost_k", 0)
    card.attack = data.get("attack", 0)
    card.defense = data.get("defense", 0)
    card.vision_range = data.get("vision_range", "")
    card.attack_range = data.get("attack_range", "")
    card.abilities.assign(data.get("abilities", []))
    card.rarity = data.get("rarity", "common")
    card.art = data.get("art", "")
    card.flavor_text = data.get("flavor_text", "")
    cards[card.id] = card

# 卡牌数据结构，对应 JSON 中一张卡牌的所有字段
class CardData:
    extends Resource

    @export var id: String = ""
    @export var card_name: String = ""
    @export var nation: String = ""
    @export var type: String = ""           # "unit" 或 "order"
    @export var unit_class: String = ""     # cavalry/infantry/tank/fighter/bomber/artillery/fortification
    @export var cost_g: int = 0             # 生产所需经济
    @export var cost_k: int = 0             # 部署所需指挥点
    @export var attack: int = 0
    @export var defense: int = 0
    @export var vision_range: String = ""   # adjacent_4 / adjacent_8_forward / front_3x2 等
    @export var attack_range: String = ""
    @export var abilities: Array[String] = []
    @export var rarity: String = "common"   # common / silver / gold
    @export var art: String = ""
    @export var flavor_text: String = ""
