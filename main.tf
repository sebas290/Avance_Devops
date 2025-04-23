provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "mi_vpc" {
  cidr_block = "10.10.0.0/16"
  tags = { Name = "mi_vpc" }
}

resource "aws_subnet" "publica" {
  vpc_id                  = aws_vpc.mi_vpc.id
  cidr_block              = "10.10.0.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"
  tags = { Name = "subred_publica" }
}

resource "aws_subnet" "privada" {
  vpc_id            = aws_vpc.mi_vpc.id
  cidr_block        = "10.10.1.0/24"
  availability_zone = "us-east-1a"
  tags = { Name = "subred_privada" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.mi_vpc.id
  tags = { Name = "internet_gw" }
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.mi_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = { Name = "rt_publica" }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.publica.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_security_group" "web_sg" {
  name        = "web_sg"
  description = "Permite HTTP y SSH"
  vpc_id      = aws_vpc.mi_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.10.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "web_sg" }
}

resource "aws_security_group" "rds_sg" {
  name        = "rds_sg"
  description = "Permite acceso desde web_sg"
  vpc_id      = aws_vpc.mi_vpc.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "rds_sg" }
}

resource "aws_db_subnet_group" "db_subnet" {
  name       = "db_subnet_group"
  subnet_ids = [aws_subnet.privada.id]
  tags = { Name = "db_subnet" }
}

resource "aws_rds_cluster" "aurora_cluster" {
  cluster_identifier      = "avance-db-cluster"
  engine                  = "aurora-mysql"
  engine_version          = "8.0.mysql_aurora.3.05.2"
  database_name           = "Avance"
  master_username         = "Sebas"
  master_password         = "Devops"
  db_subnet_group_name    = aws_db_subnet_group.db_subnet.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  skip_final_snapshot     = true
  tags = { Name = "AvanceAuroraCluster" }
}

resource "aws_rds_cluster_instance" "aurora_instance" {
  identifier         = "avance-db-instance"
  cluster_identifier = aws_rds_cluster.aurora_cluster.id
  instance_class     = "db.t3.medium"
  engine             = "aurora-mysql"
  publicly_accessible = false
  tags = { Name = "AuroraInstance" }
}

resource "aws_instance" "web" {
  ami           = "ami-084568db4383264d4"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.publica.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  key_name = "labuser"

  user_data = <<-EOF
              #!/bin/bash
              apt update -y
              apt install -y python3-pip python3-flask mysql-client
              pip3 install flask flask-mysqldb

              cat <<EOPYTHON > /home/ubuntu/app.py
              from flask import Flask, request, jsonify
              import MySQLdb
              app = Flask(__name__)
              
              db = MySQLdb.connect(
                  host="${aws_rds_cluster.aurora_cluster.endpoint}",
                  user="Sebas",
                  passwd="Devops",
                  db="Avance"
              )
              
              @app.route("/productos", methods=["GET"])
              def obtener():
                  cursor = db.cursor()
                  cursor.execute("SELECT * FROM productos")
                  rows = cursor.fetchall()
                  return jsonify(rows)
              
              @app.route("/productos", methods=["POST"])
              def insertar():
                  data = request.get_json()
                  cursor = db.cursor()
                  cursor.execute("INSERT INTO productos (nombre, precio, imagen, cantidad) VALUES (%s, %s, %s, %s)",
                      (data["nombre"], data["precio"], data["imagen"], data["cantidad"]))
                  db.commit()
                  return jsonify({"mensaje": "Insertado"})
              
              @app.route("/productos/<int:id>", methods=["DELETE"])
              def eliminar(id):
                  cursor = db.cursor()
                  cursor.execute("DELETE FROM productos WHERE id = %s", (id,))
                  db.commit()
                  return jsonify({"mensaje": "Eliminado"})
              
              @app.route("/comprar/<int:id>", methods=["POST"])
              def comprar(id):
                  cursor = db.cursor()
                  cursor.execute("UPDATE productos SET cantidad = cantidad - 1 WHERE id = %s", (id,))
                  db.commit()
                  return jsonify({"mensaje": "Compra realizada"})

              if __name__ == "__main__":
                  app.run(host="0.0.0.0", port=80)
              EOPYTHON

              cat <<EOMYSQL > /home/ubuntu/init.sql
              CREATE DATABASE IF NOT EXISTS Avance;
              USE Avance;
              CREATE TABLE IF NOT EXISTS productos (
                  id INT AUTO_INCREMENT PRIMARY KEY,
                  nombre VARCHAR(100),
                  precio FLOAT,
                  imagen TEXT,
                  cantidad INT
              );
              EOMYSQL

              mysql -h ${aws_rds_cluster.aurora_cluster.endpoint} -u Sebas -pDevops < /home/ubuntu/init.sql
              EOF

  tags = { Name = "WebServer" }
}