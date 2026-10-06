## Index

* [now_s](#now_s)
* [have_cmd](#have_cmd)
* [is_tty](#is_tty)
* [bar_segment](#bar_segment)
* [bar_text](#bar_text)
* [bar_paint](#bar_paint)
* [bar_tick](#bar_tick)
* [emit_line](#emit_line)
* [bar_suspend](#bar_suspend)
* [bar_resume](#bar_resume)
* [close_prompt_line](#close_prompt_line)
* [bar_finalize](#bar_finalize)
* [log](#log)
* [log_raw](#log_raw)
* [log_info](#log_info)
* [log_warn](#log_warn)
* [log_error](#log_error)
* [say](#say)
* [die](#die)
* [read_answer](#read_answer)
* [confirm](#confirm)
* [size_to_mb](#size_to_mb)
* [confirm_choice](#confirm_choice)
* [in_list](#in_list)
* [stage_begin](#stage_begin)
* [stage_end](#stage_end)
* [code_weight](#code_weight)
* [aggregate_code](#aggregate_code)
* [total_start](#total_start)
* [total_seconds](#total_seconds)
* [register_tmp](#register_tmp)
* [cleanup_tmps](#cleanup_tmps)

### now_s

Devuelve los segundos desde la época Unix; base de todos los cronómetros.

_Function has no arguments._

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* Los segundos desde la época, sin salto de línea.

### have_cmd

Indica si un comando está disponible en el PATH.

#### Example

```bash
have_cmd VBoxManage && echo disponible
```

#### Arguments

* **$1** (string): Nombre del comando a comprobar (vacío no permitido).

#### Exit codes

* **0**: El comando está en el PATH.
* **1**: El comando no está.

### is_tty

Indica si stderr es un terminal; ahí cabe la barra de progreso.

_Function has no arguments._

#### Exit codes

* **0**: stderr es un terminal.
* **1**: stderr no es un terminal.

### bar_segment

Compone el segmento "[n/T] [barra] nombre" de la etapa en curso, sin el tiempo,
para componer tanto la barra viva como el cierre de la etapa.
La barra tiene 20 celdas: "=" para las ya contadas, ">" para la etapa en curso y espacios para las restantes.

_Function has no arguments._

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* El segmento de la barra, sin salto de línea.

### bar_text

Devuelve el segmento de la barra con el tiempo transcurrido de la etapa en segundos.

_Function has no arguments._

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* El segmento de la barra seguido de " <n>s", sin salto de línea.

### bar_paint

Pinta la barra de la etapa en su propio renglón, el último del bloque, sin cerrarlo:
el cursor queda al final de la barra y lo que la etapa escriba (registros, salidas del invitado,
preguntas) la empuja hacia arriba.
Solo actúa cuando hay etapa abierta y stderr es terminal; en cualquier otra salida la etapa usa la línea plana.

_Function has no arguments._

#### Variables set

* **VBOXDISK_STAGE_PAINTED** (int): 1 cuando la barra queda pintada.

#### Exit codes

* **0**: Siempre (no pinta si no corresponde).

#### Output on stderr

* La barra de progreso con \r y \033[K, sin salto de línea.

### bar_tick

Refresca la barra en su renglón con el tiempo actualizado, limpiándolo y volviéndolo
a escribir sin salto de línea, de modo que el cursor sigue al final de la barra.
Sin barra pintada o sin terminal no hace nada.

_Function has no arguments._

#### Exit codes

* **0**: Siempre.

#### Output on stderr

* La barra de progreso actualizada con \r y \033[K, sin salto de línea.

### emit_line

Escribe una línea empujando la barra hacia arriba: limpia su renglón, pone el mensaje
y repite la barra debajo, sin cerrarla, para que siempre quede al final.
Con la barra pintada toda la salida de la etapa debe pasar por aquí; cualquier mensaje más ancho
que el terminal se parte en varias filas y la barra desciende igual, sin contarlas.

#### Arguments

* **$1** (string): Texto de la línea a emitir (se le agrega un salto de línea).

#### Exit codes

* **0**: Siempre.

#### Output on stderr

* El texto con salto de línea y, con la barra pintada, la barra repetida debajo.

### bar_suspend

Retira la barra del renglón antes de escribir un prompt, para que la pregunta ocupe
ese renglón. Sin barra pintada no hace nada.

_Function has no arguments._

#### Variables set

* **VBOXDISK_STAGE_PAINTED** (int): 0 al retirar la barra.

#### Exit codes

* **0**: Siempre.

#### Output on stderr

* Limpieza del renglón con \r\033[K (solo si había barra pintada).

### bar_resume

Vuelve a pintar la barra en el renglón corriente, al terminar la respuesta al prompt.
Fuera de una etapa no hace nada.

_Function has no arguments._

#### Exit codes

* **0**: Siempre.

#### See also

* [bar_paint()](#bar_paint)

### close_prompt_line

Cierra el renglón de un prompt cuya respuesta no llegó completa y repite la barra,
para que el mensaje siguiente no se pegue a la pregunta.

_Function has no arguments._

#### Exit codes

* **0**: Siempre.

#### Output on stderr

* Un salto de línea y, con etapa abierta, la barra debajo.

### bar_finalize

En la trampa de salida cierra el renglón de una barra que quede pintada, para que el
prompt no se pegue al avance. Sin barra pintada no hace nada.

_Function has no arguments._

#### Variables set

* **VBOXDISK_STAGE_PAINTED** (int): 0 al cerrar el renglón.

#### Exit codes

* **0**: Siempre.

#### Output on stderr

* Un salto de línea (solo si había barra pintada).

### log

Registra un mensaje con sello de tiempo y nivel: lo emite en stderr empujando la
barra hacia arriba y, si hay bitácora, agrega la misma línea al fichero de la corrida.

#### Arguments

* **$1** (string): Nivel del mensaje (p. ej. INFO, WARN, ERROR).
* **$2** (string): Mensaje; los argumentos a partir de $2 se unen con un espacio (variadic).

#### Exit codes

* **0**: Siempre.

#### Output on stderr

* La línea "YYYY-MM-DD HH:MM:SS [nivel] mensaje" (con la barra repetida debajo si está pintada).

### log_raw

Conserva la salida cruda de un comando externo (el chatter del hipervisor) en la
bitácora sin sacarla al terminal, para que no contamine la barra ni la salida visible.

#### Arguments

* **$1** (string): Línea a guardar; cadena vacía no hace nada.

#### Exit codes

* **0**: Siempre (también con cadena vacía).

### log_info

Atajo de log() con nivel INFO: mensaje con sello de tiempo en stderr y, si hay
bitácora, la misma línea en el fichero de la corrida.

#### Arguments

* **$1** (string): Mensaje; los argumentos se unen con un espacio (variadic).

#### Exit codes

* **0**: Siempre.

### log_warn

Atajo de log() con nivel WARN, con el mismo formato que log_info().

#### Arguments

* **$1** (string): Mensaje; los argumentos se unen con un espacio (variadic).

#### Exit codes

* **0**: Siempre.

### log_error

Atajo de log() con nivel ERROR, con el mismo formato que log_info().

#### Arguments

* **$1** (string): Mensaje; los argumentos se unen con un espacio (variadic).

#### Exit codes

* **0**: Siempre.

### say

Escribe datos por stdout, separados del progreso y los registros.

#### Arguments

* **$1** (string): Texto; los argumentos se unen con un espacio (variadic).

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* El texto seguido de salto de línea.

### die

Registra el error con nivel ERROR y termina el proceso con el código dado.

#### Arguments

* **$1** (int): Código de salida (los del proyecto: 0 ok, 1 uso/configuración, 2 comunicación, 3 almacenamiento, 4 cancelado).
* **$2** (string): Mensaje del error; los argumentos a partir de $2 se unen con un espacio (variadic).

#### Exit codes

* $**1**: Termina con el código indicado en $1.

#### Output on stderr

* El mensaje con sello de tiempo y nivel [ERROR], con la barra empujada hacia arriba.

### read_answer

Imprime el prompt en stderr y devuelve la respuesta por stdout.
Lee de stdin cuando es terminal y, si la entrada está redirigida, de la terminal de control mientras
stderr también lo sea (el caso de una corrida lanzada desde una terminal con la entrada tomada por
otro proceso).
Se invoca siempre entre $( ), de modo que el cambio de stdin no escapa al llamador.

#### Arguments

* **$1** (string): Prompt a mostrar (se le agrega un espacio; la respuesta no forma parte del prompt).

#### Exit codes

* **0**: Lectura completa.
* **1**: No hay terminal donde preguntar.
* **2**: La lectura se interrumpe.

#### Output on stdout

* La respuesta leída, sin salto de línea.

#### Output on stderr

* El prompt; la barra se retira antes y se repite después.

### confirm

Confirmación de los caminos peligrosos: pregunta en la terminal y acepta como
afirmativas s, si, sí, y o yes, sin distinción de mayúsculas.
-y (VBOXDISK_ASSUME_YES=1) la omite y, sin terminal donde preguntar, se cancela porque no hay a
quien formularla.

#### Arguments

* **$1** (string): Pregunta; se le agrega " [s/N]".

#### Exit codes

* **0**: Confirmada (respuesta afirmativa o -y).
* **4**: Cancelada: sin terminal, lectura interrumpida o respuesta no afirmativa (VBOXDISK_E_CANCEL).

#### Output on stderr

* El prompt y los registros de la decisión (INFO con -y, ERROR sin terminal, WARN al cancelar).

### size_to_mb

Normaliza un tamaño declarado a megabytes.
Admite el entero solo (megabytes) o el sufijo m|mb|g|gb|t|tb, sin distinción de mayúsculas, con
1 g = 1024 MB y 1 t = 1024*1024 MB; una cifra cero o una forma desconocida no es un tamaño válido.

#### Example

```bash
size_to_mb 4g   # imprime 4096
```

#### Arguments

* **$1** (string): Tamaño a convertir, p. ej. "512", "512m", "4g", "1t"; sin espacios y sin vacío.

#### Exit codes

* **0**: Conversión exitosa.
* **1**: Forma desconocida o tamaño cero.

#### Output on stdout

* El tamaño en MB, sin salto de línea.

### confirm_choice

Decide sobre un disco registrado que ya no figura en el archivo declarativo:
eliminarlo, dejarlo inactivo o saltarlo.
Acepta e|eliminar|d, i|inactivar y s|saltar (respuesta vacía = saltar), sin distinción de
mayúsculas; una respuesta no reconocida vuelve a preguntar. -y elige eliminar; sin terminal no hay
a quien preguntar y la corrida se cancela.

#### Arguments

* **$1** (string): Pregunta; se le agrega " [e]liminar/[i]nactivar/[s]altar:".

#### Variables set

* **CHOICE** (string): Letra elegida: "e" eliminar, "i" inactivar o "s" saltar; queda vacía si se cancela.

#### Exit codes

* **0**: Decisión tomada (CHOICE con e, i o s).
* **4**: Cancelada: sin terminal o lectura interrumpida (VBOXDISK_E_CANCEL).

#### Output on stderr

* El prompt y los registros de la decisión o de la respuesta no reconocida.

### in_list

Indica si un valor figura en la lista.

#### Arguments

* **$1** (string): Valor a buscar.
* **$2** (string): Elementos de la lista; todos los argumentos a partir de $2 se comparan con coincidencia exacta, sin patrones (variadic).

#### Exit codes

* **0**: El valor figura en la lista.
* **1**: El valor no figura.

### stage_begin

Abre la etapa n, reinicia su cronómetro y pinta la barra si stderr es terminal.

#### Arguments

* **$1** (int): Número de etapa, mostrado como [n/T] con T = VBOXDISK_STAGE_TOTAL (5 por defecto).
* **$2** (string): Nombre de la etapa, visible en la barra y en el registro.

#### Variables set

* **VBOXDISK_STAGE_N** (int): Número de la etapa en curso.
* **VBOXDISK_STAGE_NAME** (string): Nombre de la etapa en curso.
* **VBOXDISK_STAGE_T0** (int): Segundos desde la época al abrir la etapa (cronómetro de la etapa).
* **VBOXDISK_STAGE_OPEN** (int): 1 mientras la etapa está abierta.
* **VBOXDISK_STAGE_PAINTED** (int): 0 al abrir; queda en 1 si la barra se pinta.

#### Exit codes

* **0**: Siempre.

#### Output on stderr

* La barra de progreso (solo si stderr es terminal).

### stage_end

Cierra la etapa, informa su duración y la registra en la bitácora.
Un código cero la cierra con "listo"; cualquier otro, con "fallida", porque una etapa que devolvió
error no se completó. Con la barra pintada el cierre la reescribe en su renglón y lo cierra con
salto de línea, quedando el resumen debajo; sin barra (salida sin terminal) se emite la línea
plana con la misma distinción.

#### Arguments

* **$1** (int): Código de la etapa; opcional, por defecto 0. Cero cierra como "listo" y cualquier otro valor como "fallida".

#### Variables set

* **VBOXDISK_STAGE_OPEN** (int): 0 al cerrar la etapa.
* **VBOXDISK_STAGE_PAINTED** (int): 0 al cerrar la etapa.

#### Exit codes

* **0**: Siempre; el código recibido solo clasifica el resumen.

#### Output on stderr

* El resumen "[n/T] nombre ... listo/fallida (Xs)" y el registro INFO o ERROR con la
  duración en segundos.

### code_weight

Severidad de los códigos de salida: los globales 1 y 4 dominan; entre los
particulares, 3 precede a 2 (Tabla tab:codigos).

#### Arguments

* **$1** (int): Código de salida; cualquier valor fuera de 0-4 pesa 0.

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* La severidad sin formato: 40 (1), 30 (4), 20 (3), 10 (2) o 0 (el resto).

### aggregate_code

Devuelve el código final de la corrida: el de mayor severidad entre los devueltos por
cada vm (0 si ninguna falló).

#### Example

```bash
  aggregate_code 0 3   # imprime 3
@see code_weight()
```

#### Arguments

* **$1** (int): Códigos a comparar; todos los argumentos se evalúan y, sin argumentos, devuelve 0 (variadic).

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* El código final, sin salto de línea.

### total_start

Marca el inicio del cronómetro total de la corrida, informado en el resumen final.

_Function has no arguments._

#### Variables set

* **VBOXDISK_TOTAL_T0** (int): Segundos desde la época al iniciar el cronómetro.

#### Exit codes

* **0**: Siempre.

### total_seconds

Devuelve los segundos transcurridos desde total_start().

_Function has no arguments._

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* Los segundos transcurridos, sin salto de línea.

#### See also

* [total_start()](#total_start)

### register_tmp

Registra un temporal del host para su destrucción en la trampa de salida.

#### Arguments

* **$1** (path): Ruta del fichero o directorio temporal a acumular.

#### Variables set

* **VBOXDISK_TMP_PATHS** (array): Rutas acumuladas para destruir después.

#### Exit codes

* **0**: Siempre.

#### See also

* [cleanup_tmps()](#cleanup_tmps)

### cleanup_tmps

Trampa de salida: cierra el renglón de una barra pintada, borra primero el directorio
en el invitado (necesita el fichero de credenciales temporal) y después destruye ese fichero en el
host con shred y, si falla, con rm. Los fallos de borrado se descartan.

_Function has no arguments._

#### Output on stderr

* Un salto de línea si había barra pintada (el resto de la salida depende de las funciones
  del invitado que invoca).

#### See also

* [bar_finalize()](#bar_finalize)

