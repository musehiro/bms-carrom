extends Node

## Sfx — autoload. Procedural wooden sounds (no audio files needed):
## click (striker/coin impact, pitch varies with force), thock (cushion),
## sink + chime (pocket), foul buzz. All generated as AudioStreamWAV.
## The win cheer is the one file-based sound: res://audio/cheer.wav
## (crowd cheer, supplied alongside this code) — played through the same
## 6-player pool on the Master bus, so the mute toggle respects it.

const CHEER := preload("res://audio/cheer.wav")

var _players: Array = []
var _enabled := true

func _ready() -> void:
	for i in range(6):
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)

func set_enabled(on: bool) -> void:
	_enabled = on

func _play(stream: AudioStreamWAV, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if not _enabled:
		return
	for p in _players:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = pitch
			p.play()
			return
	_players[0].stream = stream
	_players[0].volume_db = volume_db
	_players[0].pitch_scale = pitch
	_players[0].play()

func _tone(freq: float, duration: float, decay: float, noise: float = 0.0, sample_rate: int = 22050) -> AudioStreamWAV:
	var frames := int(sample_rate * duration)
	var data := PackedByteArray()
	data.resize(frames * 2)
	for i in range(frames):
		var t := float(i) / sample_rate
		var env := exp(-t * decay)
		var s := sin(TAU * freq * t) * env
		if noise > 0.0:
			s += (randf() * 2.0 - 1.0) * noise * env
		var v := int(clampf(s, -1.0, 1.0) * 32767.0)
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = data
	return stream

func click(force: float = 0.7) -> void:
	# Short wooden click; pitch rises with impact force.
	_play(_tone(950.0 + force * 500.0, 0.06, 90.0, 0.5), -6.0 + force * 4.0, 0.9 + force * 0.3)

func cushion() -> void:
	_play(_tone(320.0, 0.07, 70.0, 0.35), -10.0, 1.0)

func pocket() -> void:
	_play(_tone(660.0, 0.25, 18.0, 0.1), -4.0, 1.0)
	_play(_tone(990.0, 0.3, 16.0, 0.05), -8.0, 1.0)

func foul() -> void:
	_play(_tone(160.0, 0.3, 12.0, 0.15), -6.0, 0.8)

func win() -> void:
	_play(_tone(523.0, 0.5, 8.0), -4.0, 1.0)
	_play(_tone(784.0, 0.5, 8.0), -6.0, 1.0)

## Win cheer (crowd applause, res://audio/cheer.wav). Same pool, same
## Master bus as every other sound — the mute toggle respects it.
func cheer() -> void:
	_play(CHEER, -4.0, 1.0)

func tap() -> void:
	_play(_tone(1200.0, 0.04, 120.0, 0.2), -12.0, 1.0)
