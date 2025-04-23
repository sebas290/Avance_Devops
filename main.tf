
provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "main" {
  cidr_block = "10.10.0.0/20"
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = { Name = "ProyectoVPC" }
}

resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.0.0/24"
  map_public_ip_on_launch = true
  availability_zone = "us-east-1a"
  tags = { Name = "PublicSubnet" }
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.1.0/24"
  availability_zone = "us-east-1a"
  tags = { Name = "PrivateSubnet" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "IGW" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "PublicRouteTable" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# Jump Server SG
resource "aws_security_group" "jump_sg" {
  name        = "jump_sg"
  description = "Security group for Jump Server"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Permitir RDP desde cualquier IP (o mejor: limitar a tu IP)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Web Server SG
resource "aws_security_group" "web_sg" {
  name        = "web_sg"
  description = "Security group for Web Server"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.jump_sg.id]  
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "RDSSG"
  description = "Access from WebServer"
  vpc_id      = aws_vpc.main.id

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
}

resource "aws_instance" "jump_server" {
  ami                         = "ami-0c765d44cf1f25d26"
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.public_subnet.id
  associate_public_ip_address = true
  key_name                    = "labsuser"
  vpc_security_group_ids      = [aws_security_group.jump_sg.id]
  tags = { Name = "JumpServer" }
}

resource "aws_instance" "web_server" {
  ami                         = "ami-0e449927258d45bc4"
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.public_subnet.id
  associate_public_ip_address = true
  key_name                    = "labsuser"
  vpc_security_group_ids      = [aws_security_group.web_sg.id]

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
                  host="${aws_db_instance.mysql.endpoint}",
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

              mysql -h ${aws_db_instance.mysql.endpoint} -u Sebas -pDevops < /home/ubuntu/init.sql
              EOF

  tags = { Name = "WebServer" }
}

resource "aws_db_subnet_group" "db_subnet" {
  name       = "rds-subnet"
  subnet_ids = [aws_subnet.private_subnet.id]
  tags = { Name = "DBSubnetGroup" }
}

resource "aws_db_instance" "mysql" {
  identifier              = "avance-db"
  engine                  = "aurora-mysql"
  instance_class          = "db.t3.medium"
  allocated_storage       = 20
  username                = "Sebas"
  password                = "Devops"
  db_subnet_group_name    = aws_db_subnet_group.db_subnet.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  skip_final_snapshot     = true
  availability_zone       = "us-east-1a"
  publicly_accessible     = false
  engine_version          = "5.7.mysql_aurora.2.07.1"
  tags = { Name = "AvanceDB" }
}
