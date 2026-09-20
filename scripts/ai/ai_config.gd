extends RefCounted
class_name AIConfig

## AI 难度参数（docs/ai-design.md 第 4 节）— 纯数据，评估器读取
## 新增难度只需在此加一个配置项，不需要改评估器结构

var noise: float = 12.0        # 评分噪声幅度（±）
var pool: int = 2              # 按分排序后从前 N 个候选中随机挑选
var risk_aware: bool = true    # 是否评估反击/空战风险
var threat_aware: bool = true  # 是否规避更强敌人威胁（困难强化）
var aggression: float = 1.0    # 攻击评分乘数
var fort_zeal: float = 0.5     # 修筑工事倾向


static func get_config(difficulty: String) -> AIConfig:
	var cfg := AIConfig.new()
	match difficulty:
		"easy":
			cfg.noise = 40.0
			cfg.pool = 3
			cfg.risk_aware = false
			cfg.threat_aware = false
			cfg.aggression = 0.7
			cfg.fort_zeal = 0.2
		"hard":
			cfg.noise = 3.0
			cfg.pool = 1
			cfg.risk_aware = true
			cfg.threat_aware = true
			cfg.aggression = 1.0
			cfg.fort_zeal = 0.9
		_:
			pass  # normal（默认）
	return cfg
