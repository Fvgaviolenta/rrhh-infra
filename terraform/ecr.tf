resource "aws_ecr_repository" "rrhh" {
  name                 = "rrhh"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }
}

resource "aws_ecr_lifecycle_policy" "rrhh" {
  repository = aws_ecr_repository.rrhh.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conservar las últimas 30 imágenes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}
