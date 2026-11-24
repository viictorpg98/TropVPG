//
//  RadioHumor.swift
//  Trop
//
//  El NIVEL DE HUMOR de la radio (ajuste "Humor"): suave (como hasta ahora), picante (cinico, gamberro y con tacos, al estilo de las radios de Grand Theft Auto) o
//  negro (ademas, macabro y absurdo). El texto de cada nivel se pega a la ficha de la emisora, asi llega a todo lo que se escribe (piezas, secciones, gritos).
//  Los limites van SIEMPRE (nada de odio a grupos, de burlas a victimas reales ni de sexo explicito). Si Google bloquea un guion o su voz, esa pieza se reescribe en suave.
//  Los textos de abajo los lee tambien la prueba del PC (speechify-prueba\humor-prueba.py): mantener el formato de texto entre comillas triples.
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
    HUMOR (NIVEL PICANTE, al estilo de las radios de Grand Theft Auto): cinico, gamberro, de mala leche y para adultos. Los locutores son personajes con la moral por los suelos (vanidosos, hipocritas, vagos, mezquinos): se desprecian el uno al otro y desprecian un poco a los oyentes, con cariño roto. Hablan con tacos de verdad y sin pudor (carajo, coño, joder, mierda, cabron, pendejo, hijo de puta, cojones...), con la frecuencia con que lo haria gente real y sin repetir siempre el mismo. Usan dobles sentidos e insinuaciones picantes (sexo, parejas, vicios, dinero, trabajo, fracaso) sin ser explicitos. Hay satira cinica del consumismo, la publicidad, los politicos (de todos por igual), los gurus y la vida moderna. Los chistes llevan veneno, no moraleja ni mensaje bonito.
    """

    private static let dark = """
    NIVEL NEGRO: ademas, humor macabro, nihilista y absurdo: muertes comicas e INVENTADAS, apocalipsis, miseria, culpa, empresas malvadas, finales siniestros y lo peor de la naturaleza humana contado con total naturalidad.
    """

    private static let limits = """
    LIMITES (SIEMPRE, aunque el humor sea picante o negro): nada de insultos ni chistes que ataquen a grupos por su raza, origen, religion, sexo, orientacion o discapacidad; nada de sexo explicito ni de menores; nada de burlarse de desgracias, muertes o victimas REALES (ni de las de las noticias) ni de personas privadas con nombre; ninguna acusacion falsa a personas reales; nada que anime a hacerse daño. El humor negro va sobre cosas INVENTADAS, sobre los propios locutores o sobre la sociedad en general.
    """

    private static let note = """
    NOTA DE TONO (manda sobre las reglas de arriba): con este nivel de humor, las reglas que piden poca gracia, pullas pequeñas o jerga escasa se relajan: la mayoria de las piezas llevan mala leche y chiste, las pullas entre ellos pueden ser duras y los tacos son normales (varia cuales). Sigue vigente: nada de comida, no inventar datos de canciones ni artistas, frases cortas y naturales, el JSON pedido y nada de chistes de manual con moraleja.
    """

    /// El texto del nivel que se pega a la ficha ("" en suave).
    static func block(for level: RadioHumorLevel) -> String {
        switch level {
        case .mild: return ""
        case .spicy: return "\n" + spicy + "\n" + limits
        case .dark: return "\n" + spicy + "\n" + dark + "\n" + limits
        }
    }

    /// Lo que se añade al final de las reglas de una pieza o seccion para que el nivel mande sobre su tono ("" en suave).
    static func rulesNote(_ level: RadioHumorLevel) -> String {
        level == .mild ? "" : "\n\n" + note
    }

    // MARK: - Formatos picantes (mazos de las piezas entre canciones)

    /// Para las piezas cortas (entre canciones, sin charla). Con el nivel picante o negro sustituyen a los de siempre, salvo uno normal para respirar.
    static let miniFormats = [
        "una pulla venenosa de un locutor al otro (con algun taco), y anuncia la siguiente cancion",
        "una reaccion asqueada o exagerada a lo que acaba de sonar, sin afirmar nada concreto sobre la cancion",
        "una insinuacion picante y con doble sentido sobre el titulo de la cancion que VIENE, sin ser explicitos",
        "un desprecio cariñoso al oyente (que seguro que lleva horas sin hacer nada util) y anuncia la siguiente",
        "una queja cinica y concreta sobre algo cotidiano (trabajo, dinero, pareja, vecinos) y presentan la siguiente de mala gana",
        "una amenaza absurda e inofensiva de un locutor al otro y anuncia la siguiente",
        "una broma de mala leche jugando con las palabras del titulo de la cancion que ACABA de sonar",
        "presentar la siguiente cancion con naturalidad y un solo taco suelto, sin chiste"
    ]

    /// Para las charlas.
    static let charlaFormats = [
        "una queja furiosa y comica de uno de ellos sobre algo cotidiano muy concreto del TEMA, con tacos, y el otro le echa mas lena",
        "un CONSEJO MALISIMO y cinico al oyente, dicho con total seguridad, y el otro lo empeora",
        "una cuña de un producto o negocio INVENTADO (nombre inventado) con promesas ridiculas y una letra pequeña siniestra leida a toda prisa",
        "una discusion a muerte por una tonteria cotidiana muy concreta del TEMA, con insultos cariñosos y tacos",
        "uno presume de un exito mas falso que un billete de tres euros y el otro lo desmonta sin piedad",
        "una confesion vergonzosa (inventada, de uno de ellos) contada con total descaro y juzgada por el otro",
        "un debate de bar con una opinion indignante pero inofensiva sobre algo cotidiano, y el otro se escandaliza",
        "una noticia falsa y turbia de un sitio INVENTADO, con un dato absurdo y muy concreto, contada con cinismo",
        "dos colegas despellejando con cariño a un tipo inventado (el vecino, el jefe, el cuñado) con nombre de pila inventado",
        "una charla tranquila y calida de colegas, con algun taco suelto, y presentan la cancion"
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
            text = "TONO: noticiero cinico y sensacionalista al estilo de los de GTA: titulares leidos con desprecio y comentarios venenosos sobre la situacion o sobre la politica en general (todos por igual). NUNCA te rias de victimas, muertos ni heridos reales: si un titular es una desgracia, no lo elijas."
        case .tiempo:
            text = "TONO: el tiempo con mala leche: se quejan, exageran, maldicen el clima y vaticinan el apocalipsis cotidiano."
        case .anuncios:
            text = "TONO: anuncio al estilo de las radios de GTA: producto absurdo y turbio, promesas ridiculas y una LETRA PEQUEÑA SINIESTRA INVENTADA leida a toda prisa (efectos secundarios, clausulas absurdas). Humor cinico sobre el consumismo."
        case .top5:
            text = "TONO: se cachondean sin piedad de los gustos del oyente y de las veces que ha puesto cada cosa, con cariño sucio y algun taco."
        case .hoy:
            text = "TONO: comentan los hechos con cinismo y mala leche sobre el ser humano en general, sin burlarse de victimas ni de muertos reales."
        case .deportes:
            text = "TONO: humor de vestuario subido de tono, pullas duras entre ellos y a los equipos como colectivos (no a jugadores ni arbitros con nombre) y tacos de estadio."
        case .whatsapp:
            text = "TONO: los oyentes inventados pueden ser unos chalados: mensajes desquiciados, pesados, groseros o absurdos (siempre inventados), y los locutores los desprecian con cariño. La nota de voz tambien."
        }
        if level == .dark { text += " Nivel NEGRO: pueden meter un remate macabro o nihilista sobre algo INVENTADO." }
        return "\n\n" + text
    }
}
