#!/bin/bash
# Autor: Alfonso Roldán Amador
# Descripción: Virtualización en Linux

# Zona de declaración de variables
scriptdir=$(cd $(dirname "${BASH_SOURCE[0]}") >/dev/null && pwd)
nombrevm="maquina1"
dirhtml="/var/www/html"

# Zona de declaración órdenes---------------------------------------------------------------------------
echo -e "---------------------------------------------------------------------------\n"

# CREACIÓN DE LA NUEVA IMAGEN (maquina1.qcow2), QUE USE (bullseye-base.qcow2) COMO IMAGEN BASE
# Tamaño máximo = 5GB

if [ -f $nombrevm.qcow2 ]
then
  echo "La imagen $nombrevm.qcow2 ya existe."
else
  echo "Creando nueva imagen..."
  qemu-img create -f qcow2 -b bullseye-base.qcow2 $nombrevm.qcow2 5G &> /dev/null
fi
sleep 1
echo -e "\n---------------------------------------------------------------------------\n"

# Redimensionar el sistema de ficheros de la nueva imagen:
echo "Redimensionando sistema de ficheros..."

cp $nombrevm.qcow2 new$nombrevm.qcow2 &> /dev/null
virt-resize --expand /dev/vda1 $nombrevm.qcow2 new$nombrevm.qcow2 &> /dev/null
rm $nombrevm.qcow2 && mv new$nombrevm.qcow2 $nombrevm.qcow2 &> /dev/null

echo -e "\n---------------------------------------------------------------------------\n"

# CREACIÓN DE RED INTERNA (intra) con salida al exterior (NAT)------------------------------------------
# Direccionamiento = 10.10.20.0/24 | Persistencia = Si

## Definir la red 'intra' en un fichero temporal.

echo "Definiendo red intra (NAT)."

echo "<network>
<name>intra</name>
<bridge name='virbr10'/>
<forward/>
<ip address='10.10.20.1' netmask='255.255.255.0'>
  <dhcp>
    <range start='10.10.20.2' end='10.10.20.254'/>
  </dhcp>
</ip>
</network>" > intra.xml

## Crear la red (De forma persistente)

virsh -c qemu:///system net-define intra.xml &> /dev/null
echo "La red 'intra' se ha definido correctamente."

## Eliminar el fichero temporal que contiene la definición de la red.

rm intra.xml &> /dev/null
sleep 1

## Iniciar la red intra.

virsh -c qemu:///system net-start intra &> /dev/null
echo "Red intra iniciada."
sleep 1

## Configurar el inicio automático.

virsh -c qemu:///system net-autostart intra &> /dev/null
echo "La red intra se ha configurado para el inicio automático."
sleep 1

echo -e "\n---------------------------------------------------------------------------\n"

# CREACIÓN DE MÁQUINA VIRTUAL---------------------------------------------------------------------------

echo "Creando máquina virtual..."

virt-install --connect qemu:///system \
 --virt-type kvm \
 --name $nombrevm \
 --os-variant debian10 \
 --disk path=$nombrevm.qcow2 \
 --import \
 --network network=intra \
 --memory 1024 \
 --vcpus 1 \
 --noautoconsole &> /dev/null

echo "Creación de la máquina completada."

echo "Iniciando máquina.."
sleep 20

## Configurar el hostname
ip=$(virsh -c qemu:///system domifaddr $nombrevm | grep -oE "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -n 1)

echo "Estableciendo '$nombrevm' como hostname..."
ssh -i id_ecdsa debian@$ip -o "StrictHostKeyChecking no" "sudo -- bash -c 'chmod 666 /etc/hostname'" &> /dev/null
ssh -i id_ecdsa debian@$ip "sudo -- bash -c 'echo "$nombrevm" > /etc/hostname'"  &> /dev/null
ssh -i id_ecdsa debian@$ip "sudo -- bash -c 'chmod 644 /etc/hostname'"  &> /dev/null
ssh -i id_ecdsa debian@$ip "sudo sed -i 's/debian/maquina1/g' /etc/hosts" &> /dev/null
sleep 1

echo "Reiniciando máquina.."
virsh -c qemu:///system reboot $nombrevm &> /dev/null
sleep 15

echo -e "\n---------------------------------------------------------------------------\n"

# CREACIÓN DE NUEVO VOLUMEN
# Tamaño = 1 GiB | Formato = RAW | Pool = Default

echo "Creando volumen RAW de 1 GiB en la pool default..."
virsh -c qemu:///system vol-create-as --pool default --name vol1 --capacity 1G --format raw &> /dev/null
sleep 1
echo "Volumen creado."

echo -e "\n---------------------------------------------------------------------------\n"

# CONEXIÓN DE VOLUMEN CON MÁQUINA-----------------------------------------------------------------------
# FS: XFS | Mountpoint: /var/www/html | Propietario y grupo: www-data

## Añadimos el volumen a la máquina virtual.

echo "Añadiendo volumen a la máquina virtual..."
virsh -c qemu:///system attach-disk $nombrevm /var/lib/libvirt/images/vol1 vdb --driver=qemu --type disk --subdriver raw --persistent &> /dev/null
echo "El volumen ha sido asociado exitosamente."
sleep 1

vol=$(virsh -c qemu:///system domblklist maquina1 | grep vol1 | awk '{print $1}')

## Comprobamos la paquetería necesaria para crear el sistema de ficheros XFS.

echo "Comprobando la paquetería necesaria para crear sistema de ficheros XFS..."
ssh -i id_ecdsa debian@$ip "sudo apt update && sudo apt install xfsprogs" &> /dev/null
sleep 1

## Crear el sistema de fichero XFS para vol1.

echo "Creando sistema de ficheros XFS para vol1..."
ssh -i id_ecdsa debian@$ip "sudo mkfs.xfs /dev/$vol" &> /dev/null
echo "El sistema de ficheros se ha creado satisfactoriamente."
sleep 1

## Comprobar si existe el directorio /var/www/html. Si no existe, lo crea.

echo "Comprobando si existe el directorio $dirhtml, si no existe, procedemos a crearlo..."
ssh -i id_ecdsa debian@$ip "sudo mkdir -p $dirhtml" &> /dev/null

## Añadir propietario y grupo (www-data)

echo "Aplicando el propietario y grupo (www-data) al directorio $dirhtml"
ssh -i id_ecdsa debian@$ip "sudo chown www-data:www-data $dirhtml"

## Montar el volumen en /var/www/html 

echo "Configurando el volumen para montaje automático"
ssh -i id_ecdsa debian@$ip "sudo chmod 666 /etc/fstab"
ssh -i id_ecdsa debian@$ip "sudo echo -e '# $vol\n/dev/$vol  $dirhtml  xfs defaults  0 0' >> /etc/fstab"
ssh -i id_ecdsa debian@$ip "sudo chmod 644 /etc/fstab"

echo "Montando volumen en '/var/www/html'..."
ssh -i id_ecdsa debian@$ip "sudo mount -a"
echo "El volumen se ha montado correctamente."
sleep 1

echo -e "\n---------------------------------------------------------------------------\n"

# INSTALAR APACHE2, COPIAR INDEX------------------------------------------------------------------------

## Comprobar que apache2 esté instalado. En caso de que no lo esté, se instala.

echo "Instalando apache2 en caso de que no esté instalado."
ssh -i id_ecdsa debian@$ip "sudo apt update && sudo apt install apache2 -y" &> /dev/null
sleep 1

## Copiar index.html a la máquina virtual

echo "Copiando index.html..."

ssh -i id_ecdsa debian@$ip "touch index.html && sudo chmod 755 index.html"
ssh -i id_ecdsa debian@$ip "sudo echo '<!DOCTYPE html>
<html>
<head><h1>Bienvenido</h1></head>
<body><p>Este es el index</p></body>
</html>' > index.html"
echo "El index.html se ha creado correctamente."
sleep 1

echo "Copiando index.html en $dirhtml..."
ssh -i id_ecdsa debian@$ip "sudo mv index.html $dirhtml/index.html"
echo "El index.html se ha copiado correctamente."

echo -e "\n---------------------------------------------------------------------------\n"

# MOSTRAR IP DE LA MÁQUINA------------------------------------------------------------------------------

echo "IP DE LA MÁQUINA: $ip"
echo "Accede al index.html desde aquí: http://$ip"

## Pausa en el script

read -n 1 -p "Pulsa una tecla para continuar: "

echo -e "\n---------------------------------------------------------------------------\n"

# INSTALAR LXC Y CREAR CONTAINER "container1"-----------------------------------------------------------

## Instalar lxc

echo "Instalando lxc en caso de que no esté instalado."
ssh -i id_ecdsa debian@$ip "sudo apt update && sudo apt install lxc -y" &> /dev/null
echo "LXC se ha instalado correctamente."

sleep 1

# Creación de contenedor1 (Debian)

echo "Creando el contenedor..."
ssh -i id_ecdsa debian@$ip "sudo lxc-create -n contenedor1 -t debian -- -r bullseye" &> /dev/null
echo "Contenedor creado."

echo -e "\n---------------------------------------------------------------------------\n"

# AÑADIR NUEVA INTERFAZ (br0)---------------------------------------------------------------------------

## Apagamos la máquina (Recomendable antes de añadir la nueva interfaz)

echo "Apagando máquina.."
virsh -c qemu:///system shutdown $nombrevm &> /dev/null
sleep 5

## Añadimos la nueva interfaz (br0)

echo "Añadiendo nueva interfaz (br0)"
virsh -c qemu:///system attach-interface $nombrevm bridge br0 --model virtio --persistent --config &> /dev/null
echo "La intefaz br0 ha sido asociada exitosamente."
sleep 2

## Iniciamos la máquina

echo "Iniciando máquina..."
virsh -c qemu:///system start $nombrevm &> /dev/null
sleep 15

echo -e "\n---------------------------------------------------------------------------\n"

# MOSTRAR IP DE LA NUEVA INTERFAZ-----------------------------------------------------------------------
ipbr0=$(ssh -i id_ecdsa debian@$ip "ip a | egrep enp8s0 | egrep -o '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1")

echo "IP obtenida en la nueva interfaz (br0): $ipbr0"

echo -e "\n---------------------------------------------------------------------------\n"

## APAGAR MÁQUINA, AUMENTAR LA RAM, VOLVER A INICIAR MÁQUINA---------------------------------------------
## Nueva RAM: 2 GiB

### Apagamos la máquina

echo "Apagando máquina.."
virsh -c qemu:///system shutdown $nombrevm &> /dev/null
sleep 5

### Aumentamos la RAM a 2 GiB (En este caso estableceré el mismo valor para la memoria máxima y la memoria utilizada)

echo "Aumentando RAM a 2 GiB"
virt-xml -c qemu:///system  $nombrevm --edit --memory memory=2048,currentMemory=2048

## Iniciamos la máquina

echo "Iniciando máquina..."
virsh -c qemu:///system start $nombrevm &> /dev/null
sleep 15

echo -e "\n---------------------------------------------------------------------------\n"

## CREACIÓN DE INSTANTÁNEA--------------------------------------------------------------------------------

echo "Creando instantánea de la máquina..."
virsh -c qemu:///system shutdown maquina1
sleep 5
virsh -c qemu:///system snapshot-create-as $nombrevm --name instantánea1 --description "Instantanea1 - $nombrevm" --disk-only --atomic &> /dev/null
echo "Instantánea creada correctamente."

