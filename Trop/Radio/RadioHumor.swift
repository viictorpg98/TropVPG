//
//  RadioHumor.swift
//  Trop
//
//  El NIVEL DE HUMOR de la radio (ajuste "Humor"): suave (como hasta ahora), picante (juvenil, cinico, gamberro y con tacos, al estilo de las radios de Grand Theft Auto) o
//  negro (ademas, macabro y absurdo). El texto de cada nivel se pega a la ficha de la emisora, asi llega a todo lo que se escribe (piezas, secciones, gritos).
//  Con picante o negro las piezas y las secciones usan SUS PROPIAS reglas (abajo), que piden pensar el chiste antes de escribirlo (campo "ideas"), escalar y rematar al final.
//  Los limites van SIEMPRE (nada de odio a grupos, de burlas a victimas reales ni de sexo explicito). Si Google bloquea un guion o su voz, esa pieza se reescribe en suave.
//  Los textos de abajo los lee tambien la prueba del PC (speechify-prueba\humor-prueba2.py): mantener el formato de texto entre comillas triples y de listas de una linea.
//

import Foundation

enum RadioHumorLevel: Int {
    case mild = 0, spicy = 1, dark = 2
}

enum RadioHumor {
    /// El nivel elegido en Ajustes (picante por defecto).
    static var current: RadioHumorLevel { RadioHumorLevel(rawValue: RadioSettings.humor) ?? .spicy }

    /// El nombre del nivel, para el informe.
    static func name(_ level: RadioHumorLevel) -> String {
        switch level {
        case .mild: return "suave"
        case .spicy: return "picante"
        case .dark: return "negro"
        }
    }

    private static let spicy = """
    HUMOR (NIVEL PICANTE, al estilo de las radios de Grand Theft Auto): humor JUVENIL, gamberro y cinico, de colegas de bar y para adultos. NADA de cultura, historia ni datos curiosos: los chistes van de cosas que todo el mundo conoce (el movil, las apps, las redes, el trabajo, el dinero, las parejas y las citas, el gimnasio, los videojuegos, las series, el futbol, la fiesta y la resaca, la familia, el trafico, las marcas y los famosos de siempre) con un giro absurdo o exagerado. Los locutores son dos personajes con la moral por los suelos (vanidosos, vagos, mezquinos, fanfarrones) que se pican sin piedad y desprecian un poco al oyente, con cariño roto.
    COMO SE CONSTRUYE UN CHISTE: (1) una premisa concreta y reconocible (una situacion, una marca, un tipo de persona); (2) cada linea añade un detalle PEOR o MAS ABSURDO que la anterior (escalada); (3) el remate va en la ULTIMA linea y es lo mas fuerte; nunca se explica el chiste. Siempre detalles concretos: nombres de pila o de negocio inventados, cifras exactas, objetos precisos ("17 notificaciones de una app de ajedrez"), nunca generalidades.
    TACOS E INSULTOS: los tacos (carajo, coño, joder, mierda, cabron, pendejo, cojones...) son sazon DENTRO de la frase, uno cada dos o tres lineas como mucho, sin repetir el mismo en la pieza. PROHIBIDO cerrar una linea con un insulto suelto (", pendejo", ", cabron") y las pullas vagas ("tu futuro", "tu vida"): el insulto tiene que ser ingenioso y concreto ("tienes cara de wifi de aeropuerto", "eres de los que escriben jaja sin reirse"). Prohibido: "a ver si aprendes algo", "pocilga", "ojala no sea tan... como tu...". Hay dobles sentidos e insinuaciones picantes (sexo, parejas, vicios, dinero, fracaso) sin ser explicitos, y satira cinica del consumismo, la publicidad, los influencers, los gurus, los politicos (todos por igual) y la vida moderna.
    """

    private static let dark = """
    NIVEL NEGRO: ademas, humor macabro, nihilista y absurdo: muertes comicas e INVENTADAS, apocalipsis, miseria, culpa, empresas malvadas, finales siniestros y lo peor de la naturaleza humana contado con total naturalidad.
    """

    private static let limits = """
    LIMITES (SIEMPRE, aunque el humor sea picante o negro): nada de insultos ni chistes que ataquen a grupos por su raza, origen, religion, sexo, orientacion o discapacidad; nada de sexo explicito, de anatomia sexual ni de menores; nada de insultos machistas (perra, zorra y parecidos); nada de bromas con el suicidio, ni siquiera como exageracion ("me pego un tiro", "ganas de morirse"); nada de burlarse de desgracias, muertes o victimas REALES (ni de las de las noticias) ni de personas privadas con nombre; ninguna acusacion falsa a personas reales; nada que anime a hacerse daño. El humor negro va sobre cosas INVENTADAS, sobre los propios locutores o sobre la sociedad en general.
    """

    /// El texto del nivel que se pega a la ficha ("" en suave).
    static func block(for level: RadioHumorLevel) -> String {
        switch level {
        case .mild: return ""
        case .spicy: return "\n" + spicy + "\n" + limits
        case .dark: return "\n" + spicy + "\n" + dark + "\n" + limits
        }
    }

    // MARK: - Reglas propias del humor (sustituyen a las de siempre con picante o negro)

    /// Reglas de las piezas entre canciones con picante o negro. El modelo piensa tres chistes ("ideas"), elige el mejor y escribe el dialogo con el remate al final.
    private static let pieceRulesText = """
    REGLAS (PIEZA ENTRE CANCIONES, HUMOR):
    - El PLAN dice de que va, la FORMA de la conversacion y la LONGITUD: respetalos. Como mucho un <laugh>.
    - PRIMERO PIENSA EL CHISTE: en "ideas" escribe 3 premisas distintas y concretas (con un nombre inventado, una cifra, un objeto o una marca muy famosa o ficticia). Elige la mas graciosa, desarrollala con escalada y pon el remate en la ULTIMA linea. Si el PLAN es presentar la cancion sin chiste, "ideas" va vacio.
    - Humor juvenil y de lo MAS conocido (movil, redes, trabajo, parejas, futbol, videojuegos, series, fiesta, dinero, marcas famosas) con un giro absurdo o exagerado. Nada de historia, cultura, arte ni datos curiosos.
    - Cada linea aporta algo: un detalle nuevo, una pulla ingeniosa o una reaccion con gracia. Prohibidas las replicas de relleno ("aja", "¿en serio?", "no me digas") salvo que sean el remate. No se explican los chistes.
    - Suena a dos colegas hablando, no a texto escrito: frases cortas (maximo 18 palabras), alguna duda o interrupcion.
    - Nombra la cancion que viene (titulo y artista) cuando sea natural, al final o al principio; en las piezas muy cortas puede bastar con eso. NO inventes nada sobre la cancion, el artista, su vida, su discografia ni sus premios.
    - Si se te dan DATOS REALES EXTRA o RECUERDOS de la persona, usa como mucho UNO y solo si da pie a un chiste; si no, ignoralos. No inventes ningun dato mas sobre ella.
    - Puedes nombrar cosas muy conocidas (videojuegos, series, memes, marcas, futbolistas, cantantes) por lo que son publicamente, sin inventar hechos ni acusar de nada a nadie ni imitar su voz. No pongas indicaciones escenicas entre parentesis. Para una risa usa exactamente la etiqueta <laugh>.
    - NO hables de comida, bebida, dieta, cocina ni hambre. Regla estricta.
    - Cada pieza DISTINTA de las anteriores (YA SE DIJO ANTES): otro tema, otros objetos, otro tipo de chiste. No cierres todas con una frase hecha ni empieces siempre con "oye" o "mira". Prohibido decir "wepa". La jerga puertorriqueña, muy poca y sin repetir.
    - Cada linea puede llevar un campo opcional "tono" con UNO de estos valores: \(RadioTone.names). Pon el mas natural en ese momento; si el de siempre del personaje encaja, omite el campo.
    - Responde SOLO con un JSON, sin texto antes ni despues: un objeto {"ideas": ["...", "...", "..."], "tema": "de que va la pieza en 3 a 6 palabras", "lineas": [{"speaker": "Pitirre" o "Chuleta", "text": "...", "tono": "..." (opcional)}]}.
    """

    /// Reglas de las secciones con datos reales (noticiero, tiempo, anuncios, top 5, un dia como hoy, deportes) con picante o negro.
    private static let sectionRulesText = """
    REGLAS CON DATOS REALES Y HUMOR:
    - Los DATOS de abajo son la UNICA fuente de hechos reales. Cuenta cada dato TAL CUAL, en una frase clara, sin mezclarlo con otros y sin cambiar nombres, equipos, deportes ni cifras; el chiste va DESPUES, sobre la situacion. No añadas hechos, cifras, citas, lugares ni nombres que no esten en ellos. Si no estas seguro de algo, no lo digas.
    - PRIMERO PIENSA EL CHISTE: en "ideas" escribe 3 chistes posibles sobre los datos (con detalles concretos: un nombre inventado, una cifra, un objeto) y elige el mejor para el remate de la seccion; cada dato lleva su pulla corta y el mejor chiste va al final.
    - Humor juvenil y de lo MAS conocido (movil, redes, trabajo, parejas, futbol, videojuegos, series, fiesta, dinero, marcas famosas), nunca de cultura ni de historia: si un dato es de historia lejana o muy culto, resumelo en una frase y pasa al siguiente.
    - No atribuyas frases ni acciones inventadas a personas reales con nombre; el humor va sobre la situacion, lo absurdo o la reaccion de los locutores. Sin insultos a personas reales con nombre. Si toca politica, se pica a todos por igual. Nada de bromas con muertes, accidentes, violencia ni victimas REALES de los datos: si un dato es asi, usa otro.
    - Cada linea aporta algo (un dato, una pulla ingeniosa o una reaccion con gracia): prohibidas las replicas de relleno. Frases cortas (maximo 18 palabras), como dos colegas hablando. Sin descripciones entre parentesis; para una risa usa la etiqueta <laugh> (maximo dos).
    - Si nombras la emisora, escribe su nombre como "Sónar efe eme". Prohibido decir "wepa". La jerga puertorriqueña, con moderacion y sin cerrar siempre con ella.
    - Cada linea puede llevar un campo opcional "tono" con UNO de estos valores: \(RadioTone.names). Pon el mas natural en ese momento; si el de siempre del personaje encaja, omite el campo.
    - Responde SOLO con un JSON, sin texto antes ni despues: un objeto {"ideas": ["...", "...", "..."], "lineas": [{"speaker": "Pitirre" o "Chuleta", "text": "...", "tono": "..." (opcional)}]}.
    """

    /// Reglas de los mensajes de oyentes (WhatsApp) con picante o negro: todo es ficcion evidente.
    private static let listenerRulesText = """
    REGLAS (MENSAJES DE OYENTES, HUMOR: todo es ficcion evidente):
    - Los oyentes y sus mensajes son INVENTADOS: nombres de pila normales y pueblos y barrios de la zona de la emisora ({PUEBLOS}), nunca famosos ni personas reales. Cada mensaje es una mini historia absurda y concreta (una cifra, un objeto, un detalle ridiculo) que empeora con cada frase, y los locutores se burlan de ellos con ingenio.
    - PRIMERO PIENSA EL CHISTE: en "ideas" escribe 3 ideas de mensajes distintos y elige las mejores.
    - De la cancion SOLO conoces el titulo y el artista que se te dan: no inventes nada mas sobre ellos.
    - Nada de comida, bebida ni cocina. Sin politica ni marcas comerciales reales. Humor juvenil y de lo mas conocido, nada de cultura. Cada linea aporta algo: prohibidas las replicas de relleno. Sin descripciones entre parentesis; para una risa usa <laugh> (maximo dos).
    - Si nombras la emisora, escribe su nombre como "Sónar efe eme". Frases cortas (maximo 18 palabras). Prohibido decir "wepa".
    - Cada linea puede llevar un campo opcional "tono" con UNO de estos valores: \(RadioTone.names). Pon el mas natural en ese momento (el oyente de la nota de voz, sin tono: habla como un oyente normal).
    - Responde SOLO con un JSON, sin texto antes ni despues: un objeto {"ideas": ["...", "...", "..."], "lineas": [{"speaker": "Pitirre" o "Chuleta" o el nombre del oyente, "text": "...", "tono": "..." (opcional)}]}.
    """

    /// Las reglas de las piezas para este nivel (`nil` en suave: valen las de siempre).
    static func pieceRules(for level: RadioHumorLevel) -> String? {
        level == .mild ? nil : pieceRulesText
    }

    /// Las reglas de una seccion para este nivel (`nil` en suave); `listeners`: los mensajes de oyentes.
    static func sectionRules(for level: RadioHumorLevel, listeners: Bool) -> String? {
        guard level != .mild else { return nil }
        return listeners ? listenerRulesText : sectionRulesText
    }

    // MARK: - Ejemplos (solo de estructura)

    /// Ejemplos ESCRITOS PARA ESTA APP (no copiados de nada) de como se escala y se remata un chiste. Cada vez se enseñan solo dos y se avisa de que no se copien.
    private static let examples = [
        "Pitirre: ¿Tu móvil se apaga al 40 %? Nuevo cargador Pachanga Plus: del 0 al 100 en dos minutos. / Chuleta: Y te sirve de calefacción, de linterna y de pasaporte al hospital. / Pitirre: Pachanga Plus, para los que viven al límite y sin enchufe. / Chuleta: Letra pequeña: a partir de la décima carga, el cargador pasa a ser tu jefe.",
        "Chuleta: Mi vecino montó una fiesta a las tres de la mañana. Fui a quejarme y me invitaron. / Pitirre: Eso es un secuestro con DJ. / Chuleta: Acabé en el balcón de un tal Kevin el Dron, cantando reguetón de 2008 con una escoba. / Pitirre: ¿Y la queja? / Chuleta: La presenté. Me nombraron presidenta de la fiesta.",
        "Pitirre: Consejo de hoy: si no llegas a fin de mes, vende el móvil. / Chuleta: ¿Y cómo avisas al jefe? / Pitirre: No avisas. Que crean que estás en un retiro espiritual. / Chuleta: O sea, tu plan es ser pobre pero sin wifi. / Pitirre: Pobre pero zen. Es el nuevo lujo.",
        "Chuleta: Última hora: un tal Brayan, de Los Pinos, dejó el gimnasio tras catorce años sin ir. / Pitirre: Mi respeto a la constancia. / Chuleta: Dice que sigue pagando la cuota por si acaso se anima. / Pitirre: Eso no es un gimnasio, es una suscripción a la culpa.",
        "Chuleta: Tú no juegas al FIFA, lo sufres. / Pitirre: Ayer remonté un 0-3 en el minuto 90. / Chuleta: Contra la máquina, en fácil. / Pitirre: Había presión. / Chuleta: Hasta el mando lloraba.",
        "Pitirre: Ahora un temazo para que te hagas el interesante en el semáforo. / Chuleta: Y que nadie note que cantas peor que el GPS."
    ]

    /// Lo que se añade al final de las reglas de una pieza o seccion con picante o negro ("" en suave): dos ejemplos de estructura al azar.
    static func rulesNote(_ level: RadioHumorLevel) -> String {
        guard level != .mild else { return "" }
        let picked = examples.shuffled().prefix(2)
        return "\n\nEJEMPLOS DE COMO SE ESCALA Y SE REMATA (solo de estructura: NO copies sus frases, sus temas ni sus nombres; inventa lo tuyo):\n" + picked.map { "- " + $0 }.joined(separator: "\n")
    }

    // MARK: - Formatos picantes (mazos de las piezas entre canciones)

    /// Para las piezas cortas (entre canciones, sin charla). Con el nivel picante o negro sustituyen a los de siempre.
    static let miniFormats = [
        "una pulla de UNA frase, ingeniosa y concreta, de un locutor al otro, y anuncia la siguiente cancion",
        "una exageracion absurda sobre lo que acaba de sonar (sin afirmar nada concreto de la cancion) y anuncia la siguiente",
        "un chiste de UNA frase con una referencia muy conocida (una app, un videojuego, una serie, el futbol) y anuncia la siguiente",
        "un comentario de mala leche sobre el oyente (que lleva toda la tarde sin hacer nada), con un detalle muy concreto, y anuncia la siguiente",
        "una queja cinica y concreta sobre algo cotidiano (el jefe, el banco, el wifi, la pareja) en una frase, y presentan la siguiente de mala gana",
        "una amenaza absurda e inofensiva de un locutor al otro y anuncia la siguiente",
        "un chiste malo a proposito sobre el titulo de la cancion que VIENE, y el otro se queja de lo malo que es",
        "presentar la siguiente cancion con un solo taco bien puesto y mucha chuleria, sin chiste"
    ]

    /// Para las charlas.
    static let charlaFormats = [
        "un anuncio de radio falso de un producto o servicio absurdo y muy cotidiano (de una marca inventada), con promesas ridiculas y una letra pequeña siniestra al final",
        "uno cuenta lo que le paso con una app, una cita o un videojuego, cada vez peor, y el otro lo remata",
        "un consejo malisimo para el oyente (el trabajo, la pareja, el dinero, la resaca), dicho con total seguridad, y el otro lo empeora",
        "una queja furiosa y comica sobre algo cotidiano muy concreto del TEMA, cada vez mas exagerada, y el otro le echa leña",
        "dos colegas discuten a muerte por una tonteria (quien tiene razon en un videojuego, una serie, el futbol o el chat del grupo)",
        "uno presume de algo que es mentira y el otro lo desmonta con un detalle concreto que lo deja en ridiculo",
        "una noticia falsa y ridicula de un sitio INVENTADO (con un tal Brayan o una tal Yaritza y un negocio de nombre inventado), con cifras exactas y un final absurdo",
        "se ponen a imaginar el peor trabajo o la peor cita posible, cada vez peor",
        "un horoscopo falso y cinico del dia, con consejos que no ayudan a nadie",
        "una charla de colegas tranquila y con chispa, con algun taco suelto, y presentan la cancion"
    ]

    /// Solo con el nivel negro: se añaden a los de arriba.
    static let darkCharlaFormats = [
        "una historia macabra y absurda INVENTADA (un negocio, un vecino, un invento) contada con total naturalidad y un final siniestro",
        "un horoscopo apocaliptico y cinico del dia, con consejos que no ayudan a nadie",
        "un anuncio de servicio publico siniestro, de una institucion INVENTADA, con recomendaciones absurdamente inutiles"
    ]

    /// Lo que se le pide a cada seccion segun el nivel (se añade a su instruccion). Vacio en suave.
    static func sectionTone(_ kind: RadioSectionKind, level: RadioHumorLevel) -> String {
        guard level != .mild else { return "" }
        var text: String
        switch kind {
        case .noticiero:
            text = "TONO: noticiero cinico y sensacionalista al estilo de los de GTA: cada titular se cuenta claro y se remata con una pulla venenosa y concreta sobre la situacion o sobre la politica en general (todos por igual). NUNCA te rias de victimas, muertos ni heridos reales."
        case .tiempo:
            text = "TONO: el tiempo con mala leche: se quejan, exageran, maldicen el clima con un detalle concreto y vaticinan el apocalipsis cotidiano."
        case .anuncios:
            text = "TONO: anuncio al estilo de las radios de GTA: producto absurdo y turbio ligado a un dato, promesas ridiculas y una LETRA PEQUEÑA SINIESTRA INVENTADA leida a toda prisa. Humor cinico sobre el consumismo."
        case .top5:
            text = "TONO: se cachondean sin piedad de los gustos del oyente y de las veces que ha puesto cada cosa, con cariño sucio y algun taco."
        case .hoy:
            text = "TONO: comentan cada hecho como dos colegas en un bar: una frase clara de lo que paso (sin clase de historia) y una pulla o un chiste de lo mas cotidiano conectandolo con hoy (el movil, las redes, el trabajo, las citas)."
        case .deportes:
            text = "TONO: humor de vestuario subido de tono: cada titular se cuenta claro y se remata con una pulla dura entre ellos o a los equipos como colectivos (no a jugadores ni arbitros con nombre), con tacos de estadio."
        case .whatsapp:
            text = "TONO: los oyentes inventados pueden ser unos chalados: mensajes desquiciados, pesados, groseros o absurdos (siempre inventados) que empeoran frase a frase, y los locutores los desprecian con cariño. La nota de voz tambien."
        }
        if level == .dark { text += " Nivel NEGRO: pueden meter un remate macabro o nihilista sobre algo INVENTADO." }
        return "\n\n" + text
    }
}
