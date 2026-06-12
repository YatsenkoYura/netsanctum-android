class ResourceModel {
  final int? id;
  final String packageId;
  final String relativeUrl;
  final String localPath;
  final String type;

  ResourceModel({
    this.id,
    required this.packageId,
    required this.relativeUrl,
    required this.localPath,
    required this.type,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'package_id': packageId,
      'relative_url': relativeUrl,
      'local_path': localPath,
      'type': type,
    };
  }

  factory ResourceModel.fromMap(Map<String, dynamic> map) {
    return ResourceModel(
      id: map['id'],
      packageId: map['package_id'],
      relativeUrl: map['relative_url'],
      localPath: map['local_path'],
      type: map['type'],
    );
  }
}
