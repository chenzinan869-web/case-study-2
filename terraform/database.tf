resource "aws_db_subnet_group" "main" {
  name       = "innovatech-db"
  subnet_ids = aws_subnet.db[*].id
}

resource "aws_db_instance" "postgres" {
  identifier                  = "innovatech-postgres"
  engine                      = "postgres"
  engine_version              = "16"
  instance_class              = var.db_instance_class
  allocated_storage           = 20
  max_allocated_storage       = 100
  storage_encrypted           = true
  db_name                     = "soar"
  username                    = "soar_admin"
  manage_master_user_password = true # password is stored in Secrets Manager
  multi_az                    = true # "Multi-AZ + backups"
  backup_retention_period     = 7
  backup_window               = "02:00-03:00"
  db_subnet_group_name        = aws_db_subnet_group.main.name
  vpc_security_group_ids      = [aws_security_group.db.id]
  publicly_accessible         = false
  skip_final_snapshot         = true # set to false for production
}
