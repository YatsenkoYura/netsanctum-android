class PackageModel {
  final String id;
  final String title;
  final String rootUrl;
  final String status;
  final double progress;
  final String date;

  PackageModel({
    required this.id,
    required this.title,
    required this.rootUrl,
    required this.status,
    this.progress = 0.0,
    required this.date,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'root_url': rootUrl,
      'status': status,
      'progress': progress,
      'date': date,
    };
  }

  factory PackageModel.fromMap(Map<String, dynamic> map) {
    return PackageModel(
      id: map['id'],
      title: map['title'] ?? map['id'],
      rootUrl: map['root_url'],
      status: map['status'],
      progress: map['progress']?.toDouble() ?? 0.0,
      date: map['date'],
    );
  }
}
