GNU nano 7.2                                                     init.sql
CREATE DATABASE IF NOT EXISTS Avance;
USE Avance;
CREATE TABLE IF NOT EXISTS productos (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nombre VARCHAR(100),
    precio FLOAT,
    imagen TEXT,
    cantidad INT
);


