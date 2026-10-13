class KeyHandle {
  final String id;
  final String label;
  const KeyHandle({required this.id, required this.label});

  @override
  bool operator ==(Object other) => other is KeyHandle && other.id == id;

  @override
  int get hashCode => id.hashCode;

  // Logs and exceptions must never echo a full handle id
  @override
  String toString() {
    final prefix = id.length >= 6 ? id.substring(0, 6) : id;
    return 'KeyHandle($label, id=$prefix…)';
  }
}
